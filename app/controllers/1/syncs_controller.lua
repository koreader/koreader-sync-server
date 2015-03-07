local Redis = require "db.redis"

local SyncsController = {
    user_key = "user:%s:key",
    progress_key = "user:%s:document:%s:progress",
    percentage_key = "user:%s:document:%s:percentage",
    device_key = "user:%s:document:%s:device",
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
        return 200, "OK"
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
            local res = {}
            local percentage, err = redis:get(percent_key)
            if percentage and percentage ~= null then
                res.percentage = percentage
            end
            local progress, err = redis:get(progress_key)
            if progress and progress ~= null then
                res.progress = progress
            end
            local device, err = redis:get(device_key)
            if device and device ~= null then
                res.device = device
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
            local percentage = self.request.body.percentage
            local progress = self.request.body.progress
            local device = self.request.body.device
            if percentage and progress and device then
                local percent_key = string.format(self.percentage_key, username, doc)
                local progress_key = string.format(self.progress_key, username, doc)
                local device_key = string.format(self.device_key, username, doc)
                local old_percent, err = redis:get(percent_key)
                if old_percent == null or old_percent < percentage then
                    local ok, err = redis:set(percent_key, percentage)
                    if not ok then self:raise_error(2000) end
                    local ok, err = redis:set(progress_key, progress)
                    if not ok then self:raise_error(2000) end
                    local ok, err = redis:set(device_key, device)
                    if not ok then self:raise_error(2000) end
                    return 200, {
                        percentage = percentage,
                        progress = progress,
                        device = device,
                    }
                else
                    return 202, { message = "Not the furthest progress." }
                end
            else
                self:raise_error(2003)
            end
        else
            return 502, { message = "Field 'document' not provided."}
        end
    end
end

return SyncsController
