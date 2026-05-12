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
    error_document_field_missing = 2004,
    error_user_registration_disabled = 2005,
}

local null = ngx.null

local function is_valid_field(field)
    return type(field) == "string" and string.len(field) > 0
end

local function is_valid_key_field(field)
    return is_valid_field(field) and not string.find(field, ":")
end

local function hash_password(password)
    local bin = ngx.sha1_bin(password .. ":koreader-sync-salt")
    return bin:gsub(".", function(c) return string.format("%02x", string.byte(c)) end)
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
        if key and key ~= null then
            if hash_password(auth_key) == key then
                ngx.log(ngx.DEBUG, "auth ok: ", auth_user)
                return auth_user
            end
            if auth_key == key then
                redis:set(string.format(self.user_key, auth_user), hash_password(auth_key))
                ngx.log(ngx.NOTICE, "migrated password to hash: ", auth_user)
                return auth_user
            end
        end
        ngx.log(ngx.WARN, "auth failed: ", auth_user or "(nil)")
    end
end

function SyncsController:auth_user()
    if self:authorize() then
        Redis.release()
        return 200, { authorized = "OK" }
    else
        self:raise_error(self.error_unauthorized_user)
    end
end

local function is_registration_enabled(redis)
    local val = redis:get("settings:user_registration")
    if val and val ~= ngx.null then
        return val == "true"
    end
    local env = os.getenv("ENABLE_USER_REGISTRATION")
    if env == nil then return true end
    return env == "true" or env == "1"
end

function SyncsController:create_user()
    local redis = self:getRedis()

    if not is_registration_enabled(redis) then
        Redis.release()
        self:raise_error(self.error_user_registration_disabled)
    end

    if not is_valid_key_field(self.request.body.username)
    or not is_valid_field(self.request.body.password) then
        ngx.log(ngx.WARN, "user creation rejected: invalid fields")
        self:raise_error(self.error_invalid_fields)
    end

    local user_key = string.format(self.user_key, self.request.body.username)
    local user, err = redis:get(user_key)
    if user == null then
        local ok, err = redis:set(user_key, hash_password(self.request.body.password))
        if not ok then
            self:raise_error(self.error_internal)
        else
            ngx.log(ngx.INFO, "user created: ", self.request.body.username)
            Redis.release()
            return 201, { username = self.request.body.username }
        end
    elseif user then
        ngx.log(ngx.WARN, "user exists: ", self.request.body.username)
        self:raise_error(self.error_user_exists)
    else
        self:raise_error(self.error_internal)
    end
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
        res.document = doc
    end

    ngx.log(ngx.DEBUG, "get progress: ", username, " doc=", doc)
    Redis.release()
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
        ngx.log(ngx.DEBUG, "sync: ", username, " doc=", doc,
                " pct=", percentage, " dev=", device)
        Redis.release()
        return 200, {
            document = doc,
            timestamp = timestamp,
        }
    else
        self:raise_error(self.error_invalid_fields)
    end
end

-- ── Healthcheck helpers ──────────────────────────────────────────────────

local function parse_redis_info(info_str)
    local t = {}
    if type(info_str) ~= "string" then return t end
    for line in info_str:gmatch("[^\r\n]+") do
        local k, v = line:match("^([^#][^:]*):(.+)$")
        if k then t[k] = v end
    end
    return t
end

local function check_writable(path)
    local f = io.open(path .. "/.healthcheck_test", "w")
    if f then
        f:close()
        os.remove(path .. "/.healthcheck_test")
        return true
    end
    return false
end

local function fmt_uptime(seconds)
    local s = tonumber(seconds) or 0
    if s < 60 then return s .. "s" end
    if s < 3600 then return math.floor(s/60) .. "m" end
    if s < 86400 then return math.floor(s/3600) .. "h " .. math.floor((s%3600)/60) .. "m" end
    return math.floor(s/86400) .. "d " .. math.floor((s%86400)/3600) .. "h"
end

local function esc_h(s)
    if type(s) ~= "string" then return tostring(s or "") end
    return (s:gsub("[&<>\"']", { ["&"]="&amp;", ["<"]="&lt;", [">"]="&gt;", ['"']="&quot;", ["'"]="&#39;" }))
end

local STATUS_CSS = [[<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>KOReader Sync — Status</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0d0d1a;color:#ddd;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:2rem}
.status-card{background:#13132b;border:1px solid #252550;border-radius:14px;padding:2rem 2.2rem;width:100%;max-width:480px}
.status-card h1{font-size:1.2rem;color:#a78bfa;margin-bottom:.2rem}
.overall{display:flex;align-items:center;gap:.6rem;margin:.8rem 0 1.5rem;font-size:.92rem;font-weight:600}
.dot{width:10px;height:10px;border-radius:50%;flex-shrink:0}
.dot-ok{background:#4ade80;box-shadow:0 0 8px #4ade8066}
.dot-fail{background:#f87171;box-shadow:0 0 8px #f8717166}
.checks{list-style:none}
.checks li{display:flex;align-items:center;gap:.8rem;padding:.55rem 0;border-bottom:1px solid #1a1a30;font-size:.88rem}
.checks li:last-child{border-bottom:none}
.icon{width:22px;text-align:center;flex-shrink:0;font-size:.95rem}
.pass{color:#4ade80}
.fail{color:#f87171}
.info-icon{color:#555}
.label{flex:1;color:#bbb}
.value{color:#888;font-size:.82rem;text-align:right;font-family:'SF Mono',Monaco,Consolas,monospace}
.value.pass{color:#4ade80}
.value.fail{color:#f87171}
.footer{margin-top:1.2rem;padding-top:.8rem;border-top:1px solid #1a1a30;font-size:.75rem;color:#444;display:flex;justify-content:space-between}
.admin-link{color:#a78bfa;text-decoration:none;font-size:.8rem;margin-top:1rem;display:inline-block}
.admin-link:hover{text-decoration:underline}
</style></head><body>]]

local function render_status_page(checks, all_ok, redis_info)
    local p = {}
    local function w(s) p[#p+1] = s end

    w(STATUS_CSS)
    w('<div class="status-card">')
    w('<h1>&#128218; KOReader Sync</h1>')

    if all_ok then
        w('<div class="overall"><span class="dot dot-ok"></span> All Systems Operational</div>')
    else
        w('<div class="overall"><span class="dot dot-fail"></span> Degraded</div>')
    end

    w('<ul class="checks">')
    for _, c in ipairs(checks) do
        if c.check then
            local icon_cls = c.ok and "pass" or "fail"
            local icon = c.ok and "&#10003;" or "&#10007;"
            local val_cls = c.ok and "pass" or "fail"
            w('<li><span class="icon ' .. icon_cls .. '">' .. icon .. '</span>')
            w('<span class="label">' .. esc_h(c.name) .. '</span>')
            w('<span class="value ' .. val_cls .. '">' .. esc_h(c.detail) .. '</span></li>')
        else
            w('<li><span class="icon info-icon">&#8226;</span>')
            w('<span class="label">' .. esc_h(c.name) .. '</span>')
            w('<span class="value">' .. esc_h(c.detail) .. '</span></li>')
        end
    end
    w('</ul>')

    w('<div class="footer">')
    w('<span>v' .. esc_h(require("config.application").version) .. '</span>')
    w('<span>' .. os.date("%Y-%m-%d %H:%M:%S") .. '</span>')
    w('</div>')
    w('<a href="/admin" class="admin-link">&rarr; Admin Dashboard</a>')
    w('</div></body></html>')
    return table.concat(p)
end

function SyncsController:healthcheck()
    local redis = Redis:new()
    local checks = {}
    local all_ok = true

    -- Nginx: if we got here, it's running
    checks[#checks+1] = { check = true, ok = true, name = "Nginx", detail = "running" }

    -- Redis connection
    local redis_connected = redis ~= nil
    checks[#checks+1] = { check = true, ok = redis_connected, name = "Redis", detail = redis_connected and "connected" or "unreachable" }
    if not redis_connected then all_ok = false end

    -- Redis PING
    local ping_ok = false
    if redis then
        local pong = redis:ping()
        ping_ok = pong and true or false
    end
    checks[#checks+1] = { check = true, ok = ping_ok, name = "Redis PING", detail = ping_ok and "OK" or "failed" }
    if not ping_ok then all_ok = false end

    -- Redis info (non-check, informational)
    local mem_info, srv_info = {}, {}
    if redis and ping_ok then
        mem_info = parse_redis_info(redis:info("memory"))
        srv_info = parse_redis_info(redis:info("server"))
        local dbsize = redis:dbsize()

        checks[#checks+1] = { check = false, name = "Redis memory", detail = mem_info.used_memory_human or "?" }
        checks[#checks+1] = { check = false, name = "Redis keys", detail = tostring(dbsize or "?") }
        checks[#checks+1] = { check = false, name = "Redis uptime", detail = fmt_uptime(srv_info.uptime_in_seconds) }
        checks[#checks+1] = { check = false, name = "Redis version", detail = srv_info.redis_version or "?" }
    end

    -- Log directory
    local log_ok = check_writable("/app/koreader-sync-server/logs")
    checks[#checks+1] = { check = true, ok = log_ok, name = "Log directory", detail = log_ok and "writable" or "not writable" }
    if not log_ok then all_ok = false end

    -- Data directory
    local data_ok = check_writable("/var/lib/redis")
    checks[#checks+1] = { check = true, ok = data_ok, name = "Data directory", detail = data_ok and "writable" or "not writable" }
    if not data_ok then all_ok = false end

    -- User registration status
    local reg_enabled = false
    if redis and ping_ok then
        reg_enabled = is_registration_enabled(redis)
    else
        local env = os.getenv("ENABLE_USER_REGISTRATION")
        reg_enabled = env == "true" or env == "1"
    end
    checks[#checks+1] = { check = false, name = "User registration", detail = reg_enabled and "enabled" or "disabled" }

    Redis.release()

    -- Content negotiation: HTML for browsers, JSON for API clients
    local accept = ngx.ctx.original_accept or ngx.var.http_accept or ""
    if accept:find("text/html") then
        ngx.header.content_type = "text/html; charset=utf-8"
        ngx.say(render_status_page(checks, all_ok))
        return ngx.exit(all_ok and 200 or 503)
    end

    if all_ok then
        return 200, { state = 'OK' }
    end
    return 503, { state = 'FAIL' }
end

return SyncsController
