local Redis = require "db.redis"

local SyncsController = {
    user_key = "user:%s:key",
    doc_key = "user:%s:document:%s",
    progress_field = "progress",
    percentage_field = "percentage",
    device_field = "device",
    device_id_field = "device_id",
    timestamp_field = "timestamp",

    error_no_redis = 1000,
    error_internal = 2000,
    error_unauthorized_user = 2001,
    error_user_exists = 2002,
    error_invalid_fields = 2003,
    -- Do we really need to handle 'document' field specifically?
    error_document_field_missing = 2004,
    error_user_registration_disabled = 2005,
    error_account_not_found = 2006,
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

function SyncsController:getRedis()
    local redis = Redis:new()
    if not redis then
        self:raise_error(self.error_no_redis)
    else
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

    local percentage = tonumber(self.request.body.percentage)
    local progress = self.request.body.progress
    local device = self.request.body.device
    local device_id = self.request.body.device_id
    local timestamp = os.time()
    if percentage and progress and device then
        local key = string.format(self.doc_key, username, doc)
        local fields = {
            self.request.headers['x-auth-key'],
            self.percentage_field, percentage,
            self.progress_field, progress,
            self.device_field, device,
            self.timestamp_field, timestamp,
        }
        if device_id ~= nil then
            table.insert(fields, self.device_id_field)
            table.insert(fields, device_id)
        end
        local updated, err = redis:eval(update_progress_script, 2,
            string.format(self.user_key, username), key, unpack(fields))
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

return SyncsController
