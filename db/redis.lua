local Gin = require 'gin.core.gin'

-- First, specify the environment settings for this database, for instance:
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

-- Then initialize and return your database:
local Redis = {
    options = {},
}

function Redis:new()
    local redis = require("resty.redis")
    local option = DbSettings[Gin.env]
    local red = redis:new()
    red:set_timeout(1000) -- 1 sec
    local ok, err = red:connect(option.host, option.port)
    if ok then
        red:select(option.database)
        return red
    end
end

return Redis
