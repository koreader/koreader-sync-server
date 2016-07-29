local Redis = require "db.redis"

local SyncsController = {
    user_key = "user:%s:key",
    progress_key = "user:%s:document:%s:progress",
    percentage_key = "user:%s:document:%s:percentage",
    device_key = "user:%s:document:%s:device",
    device_id_key = "user:%s:document:%s:device_id",
    timestamp_key = "user:%s:document:%s:timestamp",
}

local null = ngx.null

function SyncsController:getRedis()
    local redis = Redis:new()
    if not redis then
        self:raise_error(1000)
    else
        return redis
    end
end

function SyncsController:authorize()
    local redis = self:getRedis()
    local auth_user = self.request.headers['x-auth-user']
    local auth_key = self.request.headers['x-auth-key']
    if auth_user and auth_key then
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
        self:raise_error(2001)
    end
end

function SyncsController:create_user()
    local redis = self:getRedis()
    local user_key = string.format(self.user_key, self.request.body.username or "")
    local user, err = redis:get(user_key)
    if user == null then
        ok, err = redis:set(user_key, self.request.body.password)
        if not ok then
            self:raise_error(2000)
        else
            return 201, { username = self.request.body.username }
        end
    elseif user then
        self:raise_error(2002)
    end
end

function SyncsController:get_progress()
    local redis = self:getRedis()
    local username = self:authorize()
    if not username then
        self:raise_error(2001)
    else
        local doc = self.params.document
        if doc then
            local percent_key = string.format(self.percentage_key, username, doc)
            local progress_key = string.format(self.progress_key, username, doc)
            local device_key = string.format(self.device_key, username, doc)
            local device_id_key = string.format(self.device_id_key, username, doc)
            local timestamp_key = string.format(self.timestamp_key, username, doc)
            local res = {
              document = doc,
            }
            local percentage, err = redis:get(percent_key)
            if percentage and percentage ~= null then
                res.percentage = tonumber(percentage)
            end
            local progress, err = redis:get(progress_key)
            if progress and progress ~= null then
                res.progress = progress
            end
            local device, err = redis:get(device_key)
            if device and device ~= null then
                res.device = device
            end
            local device_id, err = redis:get(device_id_key)
            if device_id and device_id ~= null then
                res.device_id = device_id
            end
            local timestamp, err = redis:get(timestamp_key)
            if timestamp and timpstamp ~= null then
                res.timpstamp = timestamp
            end
            return 200, res
        else
            self:raise_error(2003)
        end
    end
end

function SyncsController:update_progress()
    local redis = self:getRedis()
    local username = self:authorize()
    if not username then
        self:raise_error(2001)
    else
        local doc = self.request.body.document
        if doc then
            local percentage = tonumber(self.request.body.percentage)
            local progress = self.request.body.progress
            local device = self.request.body.device
            local device_id = self.request.body.device_id
            local timestamp = os.time()
            if percentage and progress and device then
                local percent_key = string.format(self.percentage_key, username, doc)
                local progress_key = string.format(self.progress_key, username, doc)
                local device_key = string.format(self.device_key, username, doc)
                local device_id_key = string.format(self.device_id_key, username, doc)
                local timestamp_key = string.format(self.timestamp_key, username, doc)
                local ok, err = redis:set(percent_key, percentage)
                if not ok then self:raise_error(2000) end
                local ok, err = redis:set(progress_key, progress)
                if not ok then self:raise_error(2000) end
                local ok, err = redis:set(device_key, device)
                if not ok then self:raise_error(2000) end
                local ok, err = redis:set(device_id_key, device_id)
                if not ok then self:raise_error(2000) end
                local ok, err = redis:set(timestamp_key, timestamp)
                if not ok then self:raise_error(2000) end
                return 200, {
                    document = doc,
                    timestamp = timestamp,
                }
            else
                self:raise_error(2003)
            end
        else
            return 502, { message = "Field 'document' not provided." }
        end
    end
end

return SyncsController
