-- Parsing and comparison of the v2 identifier list. A type is an opaque label
-- chosen by the client, stored as given and echoed back, so the set can grow
-- without the server learning anything. Pure Lua: no ngx, no redis.

local Identifiers = {}

Identifiers.max_count = 8
Identifiers.max_type_length = 32
Identifiers.max_value_length = 128

-- Neither may contain the separators used by the alias value, the stored list
-- or the query string. Values reach redis keys, so they carry the same
-- restrictions as a document field.
local type_pattern = "^[a-z][a-z0-9%-]*$"
local value_pattern = "^[A-Za-z0-9][A-Za-z0-9%-_%.]*$"

local function is_valid_type(value)
    return type(value) == "string"
        and string.len(value) <= Identifiers.max_type_length
        and string.find(value, type_pattern) ~= nil
end

local function is_valid_value(value)
    return type(value) == "string"
        and string.len(value) <= Identifiers.max_value_length
        and string.find(value, value_pattern) ~= nil
end

Identifiers.is_valid_type = is_valid_type
Identifiers.is_valid_value = is_valid_value

-- Keeps empty fields, so malformed input is rejected rather than shortened.
local function split(text, separator)
    local fields = {}
    local position = 1
    while true do
        local start_at, end_at = string.find(text, separator, position, true)
        if not start_at then
            table.insert(fields, string.sub(text, position))
            return fields
        end
        table.insert(fields, string.sub(text, position, start_at - 1))
        position = end_at + 1
    end
end

Identifiers.split = split

-- The body's `identifiers` array, in the client's order of preference.
-- Returns the list, or nil and the reason it was rejected.
function Identifiers.parse_list(raw)
    if raw == nil then
        return nil, "absent"
    end
    if type(raw) ~= "table" then
        return nil, "not a list"
    end

    local list, seen = {}, {}
    local count = 0
    for _ in pairs(raw) do
        count = count + 1
    end
    if count == 0 then
        return nil, "empty"
    end
    if count > Identifiers.max_count then
        return nil, "too many identifiers"
    end

    for index = 1, count do
        local entry = raw[index]
        if type(entry) ~= "table" then
            return nil, "entry is not an object"
        end
        if not is_valid_type(entry.type) then
            return nil, "invalid type"
        end
        if not is_valid_value(entry.value) then
            return nil, "invalid value"
        end
        if seen[entry.type] then
            return nil, "duplicate type"
        end
        seen[entry.type] = true
        table.insert(list, { type = entry.type, value = entry.value })
    end

    return list
end

-- The same list flattened to "type:digest,type:digest". A GET has no body and
-- repeated query parameters are not reliably ordered, so order lives in one.
function Identifiers.parse_query(raw)
    if raw == nil then
        return nil, "absent"
    end
    if type(raw) ~= "string" or string.len(raw) == 0 then
        return nil, "not a list"
    end

    local entries = split(raw, ",")
    if #entries > Identifiers.max_count then
        return nil, "too many identifiers"
    end

    local list, seen = {}, {}
    for _, entry in ipairs(entries) do
        local pair = split(entry, ":")
        if #pair ~= 2 then
            return nil, "malformed entry"
        end
        if not is_valid_type(pair[1]) then
            return nil, "invalid type"
        end
        if not is_valid_value(pair[2]) then
            return nil, "invalid value"
        end
        if seen[pair[1]] then
            return nil, "duplicate type"
        end
        seen[pair[1]] = true
        table.insert(list, { type = pair[1], value = pair[2] })
    end

    return list
end

--------------------------------------------------------------------------------
-- Storage encoding
--------------------------------------------------------------------------------

-- The identifiers held by the client that wrote the current progress string,
-- stored beside it so a later reader can be told what it has in common with
-- the writer rather than being left to assume.
function Identifiers.encode_list(list)
    local parts = {}
    for _, identifier in ipairs(list) do
        table.insert(parts, identifier.type .. ":" .. identifier.value)
    end
    return table.concat(parts, ",")
end

function Identifiers.decode_list(raw)
    if type(raw) ~= "string" or string.len(raw) == 0 then
        return nil
    end
    return Identifiers.parse_query(raw)
end

-- An alias records the type it was registered under so that a request which
-- names no types at all can still be told how its document was found.
function Identifiers.encode_alias(identifier_type, canonical)
    return identifier_type .. ":" .. canonical
end

function Identifiers.decode_alias(raw)
    if type(raw) ~= "string" then
        return nil
    end
    local identifier_type, canonical = string.match(raw, "^([^:]*):(.*)$")
    if not canonical or string.len(canonical) == 0 then
        return nil
    end
    return identifier_type, canonical
end

--------------------------------------------------------------------------------
-- Comparison
--------------------------------------------------------------------------------

-- How the stored progress string relates to the copy asking for it: the first
-- identifier the reader offered that the writer also held, in the reader's own
-- order of preference. Digests are compared by value; the label reported is the
-- reader's own, or the writer's when the reader named none.
--
-- This is deliberately not the same question as how the document was found. A
-- reader can match a record on its own content digest and still be reading a
-- different edition from the one that last wrote the progress string.
function Identifiers.common(reader, writer)
    if not reader or not writer then
        return nil
    end
    local writer_types = {}
    for _, identifier in ipairs(writer) do
        writer_types[identifier.value] = identifier.type
    end
    for _, identifier in ipairs(reader) do
        local writer_type = writer_types[identifier.value]
        if writer_type then
            return identifier.type or writer_type
        end
    end
    return nil
end

-- Flatten a list to the argument pairs a redis script consumes.
function Identifiers.to_arguments(list)
    local arguments = {}
    for _, identifier in ipairs(list) do
        table.insert(arguments, identifier.type)
        table.insert(arguments, identifier.value)
    end
    return arguments
end

return Identifiers
