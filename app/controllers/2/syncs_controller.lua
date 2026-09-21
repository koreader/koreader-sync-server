local Redis = require "db.redis"
local Identifiers = require "lib.identifiers"

-- Version 2 differs from version 1 in the progress endpoints alone. The other
-- actions are shared verbatim rather than reimplemented, so that nothing in
-- version 1 has to change for this version to exist: gin selects a version
-- from the Accept header before a controller is ever loaded, and a client
-- asking for v1 reaches the v1 file untouched.
local V1 = require "1/syncs_controller"

local SyncsController = {}
for name, value in pairs(V1) do
    SyncsController[name] = value
end

-- Aliases let a second copy of the same document find a record stored under a
-- digest it cannot compute. The value records the type the alias was
-- registered under so a request that names no types can still be told how its
-- document was found.
SyncsController.alias_key = "user:%s:alias:%s"
SyncsController.user_prefix = "user:%s:"

-- The identifiers held by the client that wrote the current progress string,
-- and the progress string they were recorded against. The second field exists
-- because a v1 client writing to the same document replaces the progress and
-- leaves these alone; comparing it to the stored progress is what stops us
-- attributing one client's xpointer to another client's identifiers.
SyncsController.identifiers_field = "identifiers"
SyncsController.identifiers_for_field = "identifiers_for"

local null = ngx.null

-- Whether a field is valid, i.e. not an empty string.
local function is_valid_field(field)
    return type(field) == "string" and string.len(field) > 0
end

-- Whether a field is valid as a redis key, i.e. not an empty string and contains no colon.
local function is_valid_key_field(field)
    return is_valid_field(field) and not string.find(field, ":")
end

-- Mirrors version 1's guard, kept file-local the way is_valid_key_field above
-- already is. A record is always keyed by the first identifier, which has to
-- equal the document, so guarding the document guards the identifiers with it.
local function is_servable_document(field)
    return string.match(field, "^[A-Za-z0-9_]+$") ~= nil
end

-- Walk the caller's identifiers in the caller's own order, trying each as a
-- document of its own before following it through the alias table. Precedence
-- is the client's: it decides which of its identifiers is worth trusting
-- first, and a client that sends one identifier gets the v1 lookup exactly.
local resolve_document_script = [[
local prefix = ARGV[1]
for i = 2, #ARGV, 2 do
    local id_type, digest = ARGV[i], ARGV[i + 1]
    if redis.call("EXISTS", prefix .. "document:" .. digest) == 1 then
        return { id_type, "", digest }
    end
    local alias = redis.call("GET", prefix .. "alias:" .. digest)
    if alias then
        local alias_type, canonical = string.match(alias, "^([^:]*):(.+)$")
        if canonical and redis.call("EXISTS", prefix .. "document:" .. canonical) == 1 then
            return { id_type, alias_type, canonical }
        end
    end
end
return {}
]]

-- Resolve, write and register in one operation, on the same authentication
-- check as version 1: a request that authorized before the account was deleted
-- must not recreate a document afterward, and two clients resolving the same
-- identifiers must not race into two records.
--
-- An alias is only ever created, never repointed, so the failure mode of a
-- weak identifier is that a document stops matching rather than that it
-- matches the wrong record. The two exceptions are a digest that already names
-- a document of its own, which is never shadowed, and an alias whose target no
-- longer exists, which is replaced because it can no longer resolve.
local update_progress_script = [[
if redis.call("GET", KEYS[1]) ~= ARGV[1] then
    return { 0 }
end
local prefix = ARGV[2]
local first = 4
local last = first + tonumber(ARGV[3]) * 2 - 1
local canonical, matched, alias_type = nil, "", ""
for i = first, last, 2 do
    local id_type, digest = ARGV[i], ARGV[i + 1]
    if redis.call("EXISTS", prefix .. "document:" .. digest) == 1 then
        canonical, matched, alias_type = digest, id_type, ""
        break
    end
    local alias = redis.call("GET", prefix .. "alias:" .. digest)
    if alias then
        local stored_type, target = string.match(alias, "^([^:]*):(.+)$")
        if target and redis.call("EXISTS", prefix .. "document:" .. target) == 1 then
            canonical, matched, alias_type = target, id_type, stored_type
            break
        end
    end
end
if not canonical then
    canonical, matched = ARGV[first + 1], ARGV[first]
end
redis.call("HSET", prefix .. "document:" .. canonical, unpack(ARGV, last + 1))
for i = first, last, 2 do
    local digest = ARGV[i + 1]
    if digest ~= canonical and redis.call("EXISTS", prefix .. "document:" .. digest) == 0 then
        local alias_key = prefix .. "alias:" .. digest
        local existing = redis.call("GET", alias_key)
        local live = false
        if existing then
            local _, target = string.match(existing, "^([^:]*):(.+)$")
            live = target ~= nil and redis.call("EXISTS", prefix .. "document:" .. target) == 1
        end
        if not live then
            redis.call("SET", alias_key, ARGV[i] .. ":" .. canonical)
        end
    end
end
return { 1, matched, alias_type, canonical }
]]

-- The ordered identifier list a request carries, or nil when it names none.
-- The primary is required to be the first entry so that `document` keeps
-- meaning "the identifier I would send if you only took one", and so that no
-- identifier in a v2 request is left without a type.
function SyncsController:readIdentifiers(raw, document, parse)
    if raw == nil then
        return nil
    end
    local list, reason = parse(raw)
    if not list then
        return nil, reason
    end
    if list[1].value ~= document then
        return nil, "first identifier is not the document"
    end
    for _, identifier in ipairs(list) do
        if not is_valid_key_field(identifier.value) then
            return nil, "invalid value"
        end
    end
    return list
end

-- What the caller offered, as the resolution scripts consume it. A request
-- naming no identifiers still resolves through the alias table, on its
-- document alone and with no type to report.
local function lookup_arguments(identifiers, document)
    if identifiers then
        return Identifiers.to_arguments(identifiers)
    end
    return { "", document }
end

local function reader_list(identifiers, document)
    return identifiers or { { value = document } }
end

function SyncsController:get_progress()
    local redis = self:getRedis()

    local username = self:authorize()
    if not username then
        self:raise_error(self.error_unauthorized_user)
    end

    local doc = self.params.document
    if not is_valid_key_field(doc) then
        self:raise_error(self.error_document_field_missing)
    end

    local identifiers, reason = self:readIdentifiers(self.request.uri_params.ids, doc,
        Identifiers.parse_query)
    if reason then
        self:raise_error(self.error_invalid_fields)
    end

    local prefix = string.format(self.user_prefix, username)
    local resolved, err = redis:eval(resolve_document_script, 0, prefix,
        unpack(lookup_arguments(identifiers, doc)))
    if err then
        self:raise_error(self.error_internal)
    end
    if type(resolved) ~= "table" or resolved[3] == nil or resolved[3] == null then
        -- Nothing stored under any identifier offered. Version 1 answers an
        -- unknown document with an empty body and so does this.
        return 200, {}
    end

    local match = resolved[1]
    if match == nil or match == null or match == "" then
        match = resolved[2]
    end
    if match == nil or match == null or match == "" then
        -- The document was found under the digest that was asked for, and the
        -- request said nothing about what kind of digest that is.
        match = "exact"
    end
    local canonical = resolved[3]

    local key = string.format(self.doc_key, username, canonical)
    local res = {}
    local results, err = redis:hmget(key,
                                     self.percentage_field,
                                     self.progress_field,
                                     self.device_field,
                                     self.device_id_field,
                                     self.timestamp_field,
                                     self.identifiers_field,
                                     self.identifiers_for_field)
    if err then
        self:raise_error(self.error_internal)
    end

    if results[1] and results[1] ~= null then
        res.percentage = tonumber(results[1])
    end
    if results[2] and results[2] ~= null then
        res.progress = results[2]
    end
    if results[3] and results[3] ~= null then
        res.device = results[3]
    end
    if results[4] and results[4] ~= null then
        res.device_id = results[4]
    end
    if results[5] and results[5] ~= null then
        res.timestamp = tonumber(results[5])
    end

    if next(res) then
        -- We do not want to have an almost empty table with document field only.
        res.document = canonical
        res.match = match

        -- How the document was found and how far the stored progress string
        -- can be trusted are different questions. A reader can match a record
        -- on its own content digest and still be handed an xpointer written by
        -- a different edition that reached the same record through a weaker
        -- identifier, so the writer's identifiers are compared separately.
        local writer = nil
        if results[7] ~= null and results[7] == res.progress then
            writer = Identifiers.decode_list(results[6] ~= null and results[6] or nil)
        end
        if writer then
            res.progress_match = Identifiers.common(reader_list(identifiers, doc), writer) or "none"
        else
            -- Written by a client that named no identifiers, so the record is
            -- stored under the writer's own digest and whatever resolved the
            -- lookup is also what the reader shares with the writer.
            res.progress_match = match
        end
    end

    return 200, res
end

function SyncsController:update_progress()
    local redis = self:getRedis()

    local username = self:authorize()
    if not username then
        self:raise_error(self.error_unauthorized_user)
    end

    local body = self.request.body
    if type(body) ~= "table" then
        self:raise_error(self.error_invalid_fields)
    end

    local doc = body.document
    if not is_valid_key_field(doc) then
        self:raise_error(self.error_document_field_missing)
    end
    if not is_servable_document(doc) then
        self:raise_error(self.error_document_not_servable)
    end

    local identifiers, reason = self:readIdentifiers(body.identifiers, doc,
        Identifiers.parse_list)
    if reason then
        self:raise_error(self.error_invalid_fields)
    end

    local percentage = tonumber(body.percentage)
    local progress = body.progress
    local device = body.device
    local device_id = body.device_id
    local timestamp = os.time()
    if percentage and progress and device then
        local fields = {
            self.percentage_field, percentage,
            self.progress_field, progress,
            self.device_field, device,
            self.timestamp_field, timestamp,
            -- Recorded even when empty: a later v2 write that names no
            -- identifiers must not leave an earlier client's set in place.
            self.identifiers_field, identifiers and Identifiers.encode_list(identifiers) or "",
            self.identifiers_for_field, progress,
        }
        if device_id ~= nil then
            table.insert(fields, self.device_id_field)
            table.insert(fields, device_id)
        end

        local lookup = lookup_arguments(identifiers, doc)
        local arguments = {
            self.request.headers['x-auth-key'],
            string.format(self.user_prefix, username),
            math.floor(#lookup / 2),
        }
        for _, argument in ipairs(lookup) do
            table.insert(arguments, argument)
        end
        for _, field in ipairs(fields) do
            table.insert(arguments, field)
        end

        local updated, err = redis:eval(update_progress_script, 1,
            string.format(self.user_key, username), unpack(arguments))
        if type(updated) ~= "table" then
            self:raise_error(self.error_internal)
        elseif updated[1] == 0 then
            self:raise_error(self.error_unauthorized_user)
        elseif updated[1] ~= 1 then
            self:raise_error(self.error_internal)
        end

        local match = updated[2]
        if match == nil or match == null or match == "" then
            match = updated[3]
        end
        if match == nil or match == null or match == "" then
            match = "exact"
        end

        return 200, {
            -- The digest the record is stored under, which is not necessarily
            -- the one that was sent: a client can adopt it and skip the alias
            -- lookup next time.
            document = updated[4],
            match = match,
            timestamp = timestamp,
        }
    else
        self:raise_error(self.error_invalid_fields)
    end
end

return SyncsController
