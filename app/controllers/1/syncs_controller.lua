local Redis = require "db.redis"
local Identifiers = require "lib.identifiers"

local SyncsController = {
    user_key = "user:%s:key",
    doc_key = "user:%s:document:%s",
    user_prefix = "user:%s:",
    progress_field = "progress",
    percentage_field = "percentage",
    device_field = "device",
    device_id_field = "device_id",
    timestamp_field = "timestamp",
    -- The writer's identifiers, and the progress string they were recorded
    -- against.
    identifiers_field = "identifiers",
    identifiers_for_field = "identifiers_for",

    error_no_redis = 1000,
    error_internal = 2000,
    error_unauthorized_user = 2001,
    error_user_exists = 2002,
    error_invalid_fields = 2003,
    -- Do we really need to handle 'document' field specifically?
    error_document_field_missing = 2004,
    error_user_registration_disabled = 2005,
    error_account_not_found = 2006,
    error_document_not_servable = 2007,
}

local null = ngx.null

-- Authenticate and delete in one operation. Distinguish an absent account from
-- a wrong key so callers can reconcile retries without retaining tombstones.
local delete_user_script = [[
local current_key = redis.call("GET", KEYS[1])
if current_key and current_key ~= ARGV[2] then
    return 0
end
local cursor = "0"
local prefix = ARGV[1]
local keys = {}
repeat
    local result = redis.call("SCAN", cursor, "COUNT", 100)
    cursor = result[1]
    for _, key in ipairs(result[2]) do
        if string.sub(key, 1, string.len(prefix)) == prefix then
            table.insert(keys, key)
        end
    end
until cursor == "0"

for _, key in ipairs(keys) do
    redis.call("DEL", key)
end
if not current_key then
    return 2
end
return 1
]]

-- Check authentication at the write itself: a request that authorized before
-- deletion must not recreate a document afterward.
local update_progress_script = [[
if redis.call("GET", KEYS[1]) ~= ARGV[1] then
    return 0
end
redis.call("HSET", KEYS[2], unpack(ARGV, 2))
return 1
]]

-- The same write for a request that names identifiers: resolve, write and
-- register in one operation, on the same authentication check.
--
-- An alias is only created, never repointed, so a weak identifier can stop
-- matching but cannot match the wrong record. A digest that is a document in
-- its own right is never shadowed; an alias whose target is gone is replaced.
local update_matched_script = [[
if redis.call("GET", KEYS[1]) ~= ARGV[1] then
    return { 0 }
end
local prefix = ARGV[2]
local first = 4
local last = first + tonumber(ARGV[3]) * 2 - 1
local canonical, matched
for i = first, last, 2 do
    local id_type, digest = ARGV[i], ARGV[i + 1]
    if redis.call("EXISTS", prefix .. "document:" .. digest) == 1 then
        canonical, matched = digest, id_type
        break
    end
    local alias = redis.call("GET", prefix .. "alias:" .. digest)
    local target = alias and string.match(alias, "^[^:]*:(.+)$")
    if target and redis.call("EXISTS", prefix .. "document:" .. target) == 1 then
        canonical, matched = target, id_type
        break
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
        local target = existing and string.match(existing, "^[^:]*:(.+)$")
        if not (target and redis.call("EXISTS", prefix .. "document:" .. target) == 1) then
            redis.call("SET", alias_key, ARGV[i] .. ":" .. canonical)
        end
    end
end
return { 1, matched, canonical }
]]

-- Walk the identifiers in the caller's order, trying each as a document before
-- following it through the alias table, and read the record found. A redis
-- reply stops at the first nil and HMGET answers a missing field with false, so
-- presence travels as a string of flags beside the values.
local resolve_document_script = [[
local prefix = ARGV[1]
local function read(digest, id_type)
    local fields = redis.call("HMGET", prefix .. "document:" .. digest, unpack(KEYS))
    local out = { id_type, digest, "" }
    for i = 1, #KEYS do
        out[3] = out[3] .. (fields[i] and "1" or "0")
        out[3 + i] = fields[i] or ""
    end
    return out
end
for i = 2, #ARGV, 2 do
    local id_type, digest = ARGV[i], ARGV[i + 1]
    if redis.call("EXISTS", prefix .. "document:" .. digest) == 1 then
        return read(digest, id_type)
    end
    local alias = redis.call("GET", prefix .. "alias:" .. digest)
    local target = alias and string.match(alias, "^[^:]*:(.+)$")
    if target and redis.call("EXISTS", prefix .. "document:" .. target) == 1 then
        return read(target, id_type)
    end
end
return {}
]]

-- Authenticate and update in one operation so concurrent changes using the
-- same current key cannot both succeed. Document keys are never touched.
local update_password_script = [[
if redis.call("GET", KEYS[1]) ~= ARGV[1] then
    return 0
end
redis.call("SET", KEYS[1], ARGV[2])
return 1
]]

-- Whether a field is valid, i.e. not an empty string.
local function is_valid_field(field)
    return type(field) == "string" and string.len(field) > 0
end

-- Whether a field is valid as a redis key, i.e. not an empty string and contains no colon.
local function is_valid_key_field(field)
    return is_valid_field(field) and not string.find(field, ":")
end

-- The read route binds :document against a fixed character class (see
-- gin/core/routes.lua, build_named_parameters), so an id outside it is stored
-- by PUT and then 404s at nginx before the controller is reached. Refuse it on
-- the way in rather than accepting a write that can never be read back.
local function is_servable_document(field)
    return string.match(field, "^[A-Za-z0-9_]+$") ~= nil
end

-- The identifiers a request offered, or nil when it named none. The first must
-- be the document, so `document` keeps meaning "the identifier I would send if
-- you only took one".
local function read_identifiers(raw, document, parse)
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
    return list
end

-- gin builds a controller per request, so the handle lives exactly as long as
-- the request does.
function SyncsController:getRedis()
    if self.redis then
        return self.redis
    end
    local redis = Redis:new()
    if not redis then
        self:raise_error(self.error_no_redis)
    else
        self.redis = redis
        return redis
    end
end

function SyncsController:authorize()
    local redis = self:getRedis()
    local auth_user = self.request.headers['x-auth-user']
    local auth_key = self.request.headers['x-auth-key']
    if is_valid_field(auth_key) and is_valid_key_field(auth_user) then
        local key, err = redis:get(string.format(self.user_key, auth_user))
        if auth_key == key then
            return auth_user
        end
    end
end

function SyncsController:auth_user()
    if self:authorize() then
        return 200, { authorized = "OK" }
    else
        self:raise_error(self.error_unauthorized_user)
    end
end

function SyncsController:create_user()
    local redis = self:getRedis()

    if not is_valid_key_field(self.request.body.username)
    or not is_valid_field(self.request.body.password) then
        self:raise_error(self.error_invalid_fields)
    end

    local created, err = redis:setnx(string.format(self.user_key, self.request.body.username),
        self.request.body.password)
    if created == 0 then
        self:raise_error(self.error_user_exists)
    elseif created ~= 1 then
        self:raise_error(self.error_internal)
    end
    return 201, { username = self.request.body.username }
end

function SyncsController:create_user_disabled()
    self:raise_error(self.error_user_registration_disabled)
end

function SyncsController:delete_user()
    local username = self.request.headers['x-auth-user']
    local current_key = self.request.headers['x-auth-key']
    if not is_valid_key_field(username) or not is_valid_field(current_key) then
        self:raise_error(self.error_unauthorized_user)
    end

    local redis = self:getRedis()
    local deleted, err = redis:eval(delete_user_script, 1,
        string.format(self.user_key, username), "user:" .. username .. ":", current_key)
    if deleted == 0 then
        self:raise_error(self.error_unauthorized_user)
    elseif deleted == 2 then
        self:raise_error(self.error_account_not_found)
    elseif deleted ~= 1 then
        self:raise_error(self.error_internal)
    end

    return 200, { deleted = true }
end

function SyncsController:update_password()
    local username = self.request.headers['x-auth-user']
    local current_key = self.request.headers['x-auth-key']
    if not is_valid_key_field(username) or not is_valid_field(current_key) then
        self:raise_error(self.error_unauthorized_user)
    end

    local body = self.request.body
    if type(body) ~= "table" or not is_valid_field(body.password) then
        self:raise_error(self.error_invalid_fields)
    end

    local redis = self:getRedis()
    local updated, err = redis:eval(update_password_script, 1,
        string.format(self.user_key, username), current_key, body.password)
    if updated == 0 then
        self:raise_error(self.error_unauthorized_user)
    elseif updated ~= 1 then
        self:raise_error(self.error_internal)
    end

    return 200, { updated = true }
end

-- A read that named identifiers. The record is resolved through them, and the
-- response says both how it was found and what the reader has in common with
-- the client that wrote the progress string.
local function read_matched(self, redis, username, identifiers)
    local fields = {
        self.percentage_field,
        self.progress_field,
        self.device_field,
        self.device_id_field,
        self.timestamp_field,
        self.identifiers_field,
        self.identifiers_for_field,
    }
    local call = { resolve_document_script, #fields }
    for _, field in ipairs(fields) do
        table.insert(call, field)
    end
    table.insert(call, string.format(self.user_prefix, username))
    for _, argument in ipairs(Identifiers.to_arguments(identifiers)) do
        table.insert(call, argument)
    end

    local resolved, err = redis:eval(unpack(call))
    if err then
        self:raise_error(self.error_internal)
    end
    if type(resolved) ~= "table" or resolved[2] == nil or resolved[2] == null then
        return {}
    end

    local present = resolved[3]
    local values = {}
    for index = 1, #fields do
        if string.sub(present, index, index) == "1" then
            values[index] = resolved[3 + index]
        end
    end

    local res = {}
    if values[1] then
        res.percentage = tonumber(values[1])
    end
    if values[2] then
        res.progress = values[2]
    end
    if values[3] then
        res.device = values[3]
    end
    if values[4] then
        res.device_id = values[4]
    end
    if values[5] then
        res.timestamp = tonumber(values[5])
    end
    if not next(res) then
        return res
    end

    -- The digest the record is stored under, not necessarily the one asked for.
    res.document = resolved[2]
    res.match = resolved[1]

    -- How the record was found and who wrote the progress are different
    -- questions, so the writer's identifiers are compared separately.
    local writer = values[7] == res.progress and Identifiers.decode_list(values[6]) or nil
    if writer then
        res.progress_match = Identifiers.common(identifiers, writer) or "none"
    else
        res.progress_match = res.match
    end
    return res
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

    local identifiers, reason = read_identifiers(self.request.uri_params.ids, doc,
        Identifiers.parse_query)
    if reason then
        self:raise_error(self.error_invalid_fields)
    end
    if identifiers then
        return 200, read_matched(self, redis, username, identifiers)
    end

    local key = string.format(self.doc_key, username, doc)
    local res = {}
    local results, err = redis:hmget(key,
                                     self.percentage_field,
                                     self.progress_field,
                                     self.device_field,
                                     self.device_id_field,
                                     self.timestamp_field)
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
        res.document = doc
    end

    return 200, res
end

-- A write that named identifiers. Returns the type that found the record and
-- the digest it is stored under.
local function write_matched(self, redis, username, identifiers, progress, fields)
    -- Recorded beside the progress they were written with, so identifiers are
    -- never attributed to a string their owner did not write.
    table.insert(fields, self.identifiers_field)
    table.insert(fields, Identifiers.encode_list(identifiers))
    table.insert(fields, self.identifiers_for_field)
    table.insert(fields, progress)

    local arguments = {
        self.request.headers['x-auth-key'],
        string.format(self.user_prefix, username),
        #identifiers,
    }
    for _, argument in ipairs(Identifiers.to_arguments(identifiers)) do
        table.insert(arguments, argument)
    end
    for _, field in ipairs(fields) do
        table.insert(arguments, field)
    end

    local updated, err = redis:eval(update_matched_script, 1,
        string.format(self.user_key, username), unpack(arguments))
    if type(updated) ~= "table" then
        self:raise_error(self.error_internal)
    elseif updated[1] == 0 then
        self:raise_error(self.error_unauthorized_user)
    elseif updated[1] ~= 1 then
        self:raise_error(self.error_internal)
    end

    return updated[2], updated[3]
end

function SyncsController:update_progress()
    local redis = self:getRedis()

    local username = self:authorize()
    if not username then
        self:raise_error(self.error_unauthorized_user)
    end

    local doc = self.request.body.document
    if not is_valid_key_field(doc) then
        self:raise_error(self.error_document_field_missing)
    end
    if not is_servable_document(doc) then
        self:raise_error(self.error_document_not_servable)
    end

    local identifiers, reason = read_identifiers(self.request.body.identifiers, doc,
        Identifiers.parse_list)
    if reason then
        self:raise_error(self.error_invalid_fields)
    end

    local percentage = tonumber(self.request.body.percentage)
    local progress = self.request.body.progress
    local device = self.request.body.device
    local device_id = self.request.body.device_id
    local timestamp = os.time()
    if percentage and progress and device then
        local fields = {
            self.percentage_field, percentage,
            self.progress_field, progress,
            self.device_field, device,
            self.timestamp_field, timestamp,
        }
        if device_id ~= nil then
            table.insert(fields, self.device_id_field)
            table.insert(fields, device_id)
        end

        if identifiers then
            local match, canonical = write_matched(self, redis, username, identifiers,
                progress, fields)
            return 200, {
                document = canonical,
                match = match,
                timestamp = timestamp,
            }
        end

        local key = string.format(self.doc_key, username, doc)
        local updated, err = redis:eval(update_progress_script, 2,
            string.format(self.user_key, username), key,
            self.request.headers['x-auth-key'], unpack(fields))
        if updated == 0 then
            self:raise_error(self.error_unauthorized_user)
        elseif updated ~= 1 then
            self:raise_error(self.error_internal)
        end
        return 200, {
            document = doc,
            timestamp = timestamp,
        }
    else
        self:raise_error(self.error_invalid_fields)
    end
end

function SyncsController:healthcheck()
    return 200, { state = 'OK' }
end

-- gin dispatches straight to the action and turns raise_error into a response
-- with pcall, so an action has no return point every path passes through. The
-- connection goes back to the pool here, inside the content phase: nginx
-- finalizes cosockets before log_by_lua runs, where set_keepalive fails with
-- "closed".
local function releasing(action)
    return function(self, ...)
        local ok, status, body, headers = pcall(action, self, ...)
        if self.redis then
            Redis.release(self.redis)
            self.redis = nil
        end
        if not ok then
            error(status, 0)
        end
        return status, body, headers
    end
end

for _, action in ipairs({
    "auth_user",
    "create_user",
    "create_user_disabled",
    "delete_user",
    "update_password",
    "get_progress",
    "update_progress",
    "healthcheck"
}) do
    SyncsController[action] = releasing(SyncsController[action])
end

return SyncsController
