local Gin = require 'gin.core.gin'

local DbSettings = {
    development = {
        host = "127.0.0.1",
        port = 6379,
        database = 1,
        pool = 5
    },

    test = {
        host = "127.0.0.1",
        port = 6379,
        database = 2,
        pool = 5
    },

    production = {
        host = "127.0.0.1",
        port = 6379,
        database = 3,
        pool = 5
    }
}

local Redis = {
    options = {},
}

function Redis:new()
    if ngx.ctx._redis then return ngx.ctx._redis end

    local redis = require("resty.redis")
    local option = DbSettings[Gin.env]
    local red = redis:new()
    red:set_timeout(1000)
    local ok, err = red:connect(option.host, option.port)
    if ok then
        red:select(option.database)
        ngx.ctx._redis = red
        return red
    end
end

function Redis.release()
    local red = ngx.ctx._redis
    if red then
        red:set_keepalive(10000, 100)
        ngx.ctx._redis = nil
    end
end

return Redis
