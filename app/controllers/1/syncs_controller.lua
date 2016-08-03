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
}

local null = ngx.null

-- Whether a field is valid, i.e. not an empty string.
local function is_valid_field(field)
    return string.len(field) > 0
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
    if not redis then
        self:raise_error(self.error_no_redis)
    end

    if not is_valid_key_field(self.request.body.username)
    or not is_valid_field(self.request.body.password) then
        self:raise_error(self.error_invalid_fields)
    end

    local user_key = string.format(self.user_key, self.request.body.username)
    local user, err = redis:get(user_key)
    if user == null then
        ok, err = redis:set(user_key, self.request.body.password)
        if not ok then
            self:raise_error(self.error_internal)
        else
            return 201, { username = self.request.body.username }
        end
    elseif user then
        self:raise_error(self.error_user_exists)
    else
        self:raise_error(self.error_internal)
    end
end

function SyncsController:get_progress()
    local redis = self:getRedis()
    if not redis then
        self:raise_error(self.error_no_redis)
    end

    local username = self:authorize()
    if not username then
        self:raise_error(self.error_unauthorized_user)
    end

    local doc = self.params.document
    if not is_valid_key_field(doc) then
        self:raise_error(self.error_document_field_missing)
    end

    local key = string.format(self.doc_key, username, doc)
    local res = {
      document = doc,
    }
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
        res.timpstamp = tonumber(results[5])
    end
    return 200, res
end

function SyncsController:update_progress()
    local redis = self:getRedis()
    if not redis then
        self:raise_error(self.error_no_redis)
    end

    local username = self:authorize()
    if not username then
        self:raise_error(error_unauthorized_user)
    end

    local doc = self.request.body.document
    if not is_valid_key_field(doc) then
        self:raise_error(error_document_field_missing)
    end

    local percentage = tonumber(self.request.body.percentage)
    local progress = self.request.body.progress
    local device = self.request.body.device
    local device_id = self.request.body.device_id
    local timestamp = os.time()
    if percentage and progress and device then
        local key = string.format(self.doc_key, username, doc)
        local ok, err = redis:hmset(key, {
            [self.percentage_field] = percentage,
            [self.progress_field] = progress,
            [self.device_field] = device,
            [self.device_id_field] = device_id,
            [self.timestamp_field] = timestamp,
        })
        if not ok then
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

return SyncsController
