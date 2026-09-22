local Gin = require 'gin.core.gin'

-- First, specify the environment settings for this database, for instance:
local DbSettings = {
    development = {
        host = "127.0.0.1",
        port = 6379,
        database = 3,
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
        database = 1,
        pool = 5
    }
}

-- Then initialize and return your database:
local Redis = {
    options = {},
}

-- How long an idle connection is held. config/redis.conf sets `timeout 0`, so
-- the server never closes one first.
local keepalive_timeout = 60000

-- The pool is per nginx worker and named after the database, so a connection
-- taken from it has already selected the database its name states. host and
-- port are formatted rather than concatenated: a unix socket configuration
-- leaves port unset.
local function pool_name(option)
    return string.format("%s:%s/%s", option.host, tostring(option.port), option.database)
end

function Redis:new()
    local redis = require("resty.redis")
    local option = DbSettings[Gin.env]
    local red = redis:new()
    red:set_timeout(1000) -- 1 sec
    local ok, err = red:connect(option.host, option.port, {
        pool = pool_name(option),
        pool_size = option.pool
    })
    if ok then
        if red:get_reused_times() == 0 then
            red:select(option.database)
        end
        return red
    end
end

-- Returns the connection to the pool. set_keepalive refuses a socket with an
-- unread reply or a read or write error, and close is the fallback.
function Redis.release(red)
    local option = DbSettings[Gin.env]
    if not red:set_keepalive(keepalive_timeout, option.pool) then
        red:close()
    end
end

return Redis
