local Gin = require 'gin.core.gin'
local Redis = require 'db.redis'
local null = ngx.null

local AdminController = {}

-- ── Auth ─────────────────────────────────────────────────────────────────

local COOKIE_NAME = "kos_admin"

local function admin_password()
    local p = os.getenv("ADMIN_PASSWORD")
    if p and p ~= "" then return p end
    return nil
end

local function cookie_token(password)
    local bin = ngx.sha1_bin(password .. ":kos-admin-v1")
    return bin:gsub(".", function(c) return string.format("%02x", string.byte(c)) end)
end

local function is_authenticated()
    local pwd = admin_password()
    if not pwd then return false end
    return ngx.var["cookie_" .. COOKIE_NAME] == cookie_token(pwd)
end

local function set_auth_cookie(password)
    ngx.header["Set-Cookie"] = COOKIE_NAME .. "=" .. cookie_token(password)
        .. "; Path=/; HttpOnly; SameSite=Strict"
end

local function clear_auth_cookie()
    ngx.header["Set-Cookie"] = COOKIE_NAME .. "=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
end

-- ── Helpers ──────────────────────────────────────────────────────────────

local function esc(s)
    if type(s) ~= "string" then return tostring(s or "") end
    return (s:gsub("[&<>\"']", { ["&"]="&amp;", ["<"]="&lt;", [">"]="&gt;", ['"']="&quot;", ["'"]="&#39;" }))
end

local function val(v)
    if v == nil or v == null then return nil end
    return v
end

local function fmt_time(ts)
    local n = tonumber(ts)
    if not n then return "\226\128\148" end
    return os.date("%Y-%m-%d %H:%M", n)
end

local function pct_bar(pct)
    local p = math.floor((tonumber(pct) or 0) * 100 + 0.5)
    return math.max(0, math.min(100, p))
end

local function tail_file(path, max_lines)
    local f = io.open(path, "r")
    if not f then return {} end
    local size = f:seek("end")
    if size == 0 then f:close(); return {} end
    local chunk = math.min(size, max_lines * 512)
    f:seek("set", size - chunk)
    local data = f:read("*a")
    f:close()
    local lines = {}
    for line in data:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    local start = math.max(1, #lines - max_lines + 1)
    local result = {}
    for i = start, #lines do
        result[#result + 1] = lines[i]
    end
    return result
end

local function log_path(name)
    return "/app/koreader-sync-server/logs/" .. Gin.env .. "-" .. name .. ".log"
end

local function hash_password(password)
    local bin = ngx.sha1_bin(password .. ":koreader-sync-salt")
    return bin:gsub(".", function(c) return string.format("%02x", string.byte(c)) end)
end

local function random_password()
    local bin = ngx.sha1_bin(tostring(ngx.now()) .. ":" .. tostring(math.random(1, 999999)))
    local hex = bin:gsub(".", function(c) return string.format("%02x", string.byte(c)) end)
    return hex:sub(1, 16)
end

-- ── Shared CSS ───────────────────────────────────────────────────────────

local COMMON_CSS = [[
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0d0d1a;color:#ddd;min-height:100vh}
header{background:#13132b;border-bottom:1px solid #252550}
.hdr-top{padding:1rem 2rem .4rem;display:flex;align-items:center;gap:1rem}
.hdr-top h1{font-size:1.3rem;font-weight:600;color:#a78bfa}
.hdr-top .sub{color:#555;font-size:.82rem;margin-top:.15rem}
.logout{margin-left:auto;font-size:.78rem;color:#555;text-decoration:none;background:#1e1e3a;border:1px solid #252550;padding:.3rem .9rem;border-radius:6px;transition:color .15s}
.logout:hover{color:#a78bfa}
nav{display:flex;gap:0;padding:0 2rem}
nav a{color:#666;text-decoration:none;padding:.6rem 1.2rem;font-size:.82rem;border-bottom:2px solid transparent;transition:color .15s,border-color .15s}
nav a:hover{color:#bbb}
nav a.active{color:#a78bfa;border-bottom-color:#a78bfa}
.bar{background:#13132b;border-bottom:1px solid #252550;padding:.6rem 2rem;font-size:.8rem;color:#666;display:flex;gap:2.5rem;flex-wrap:wrap}
.bar b{color:#a78bfa}
main{padding:2rem;max-width:1050px;margin:0 auto}
.card{background:#13132b;border:1px solid #252550;border-radius:10px;margin-bottom:1.5rem;overflow:hidden}
.card-head{padding:.9rem 1.5rem;border-bottom:1px solid #252550;display:flex;align-items:center;gap:.8rem}
.flash{background:#1a2a1a;border:1px solid #2a5a2a;border-radius:8px;padding:.7rem 1.2rem;margin-bottom:1.5rem;font-size:.85rem;color:#4ade80}
.flash-err{background:#2a1a1a;border-color:#5a1a1a;color:#f87171}
]]

local DASHBOARD_CSS = [[
.search-wrap{margin-bottom:1.5rem}
.search-input{width:100%;background:#13132b;border:1px solid #252550;border-radius:8px;padding:.7rem 1rem;color:#ddd;font-size:.88rem;outline:none;transition:border-color .15s}
.search-input:focus{border-color:#a78bfa}
.search-input::placeholder{color:#444}
.avatar{width:34px;height:34px;border-radius:50%;background:#a78bfa22;border:1px solid #a78bfa44;display:flex;align-items:center;justify-content:center;font-weight:700;font-size:.85rem;color:#a78bfa;flex-shrink:0}
.uname{font-weight:600;font-size:.95rem}
.badge{font-size:.75rem;color:#888;background:#1e1e3a;padding:.2rem .7rem;border-radius:10px;border:1px solid #252550}
.user-actions{margin-left:auto;display:flex;gap:.4rem}
.btn-sm{font-size:.72rem;padding:.25rem .65rem;border:1px solid #252550;border-radius:5px;background:#1e1e3a;color:#888;cursor:pointer;transition:color .15s,border-color .15s;font-family:inherit}
.btn-sm:hover{color:#a78bfa;border-color:#a78bfa}
.btn-del:hover{color:#f87171;border-color:#f87171}
.empty-docs{padding:1.2rem 1.5rem;color:#444;font-style:italic;font-size:.85rem}
table{width:100%;border-collapse:collapse}
th{padding:.55rem 1.5rem;text-align:left;font-size:.72rem;text-transform:uppercase;letter-spacing:.05em;color:#555;border-bottom:1px solid #1e1e3a;font-weight:500}
td{padding:.75rem 1.5rem;font-size:.85rem;border-bottom:1px solid #0d0d1a;vertical-align:middle}
tr:last-child td{border-bottom:none}
tr:hover td{background:#10101f}
.docname{font-family:'SF Mono',Monaco,Consolas,monospace;font-size:.78rem;color:#c4b5fd;word-break:break-all;max-width:320px}
.prog-wrap{display:flex;align-items:center;gap:.6rem}
.prog-bg{flex:1;height:5px;background:#1e1e3a;border-radius:3px;overflow:hidden;min-width:70px}
.prog-fill{height:100%;border-radius:3px;background:linear-gradient(90deg,#6d28d9,#a78bfa)}
.pct{font-size:.8rem;color:#a78bfa;font-weight:600;min-width:38px;text-align:right}
.device{font-size:.8rem;color:#777}
.devid{font-size:.72rem;color:#444;margin-top:.15rem}
.ts{font-size:.77rem;color:#555;white-space:nowrap}
.no-users{text-align:center;padding:5rem 2rem;color:#444}
.no-users h2{font-size:1.1rem;margin-bottom:.5rem;color:#555}
]]

local LOGS_CSS = [[
.log-controls{display:flex;align-items:center;gap:.8rem;margin-bottom:1.2rem}
.log-section{margin-bottom:2rem}
.log-section h2{font-size:.9rem;font-weight:600;color:#a78bfa;margin-bottom:.7rem;display:flex;align-items:center;gap:.6rem}
.log-section .cnt{font-size:.75rem;color:#555;font-weight:400;background:#1e1e3a;padding:.15rem .6rem;border-radius:8px}
.log-box{background:#0a0a14;border:1px solid #252550;border-radius:8px;padding:.8rem;max-height:500px;overflow-y:auto;font-family:'SF Mono',Monaco,Consolas,monospace;font-size:.73rem;line-height:1.6}
.log-box:empty::after{content:"No log entries yet.";color:#444;font-style:italic}
.ll{white-space:pre-wrap;word-break:break-all;padding:.1rem .4rem;border-radius:3px}
.ll:hover{background:#13132b}
.l2{color:#4ade80}.l3{color:#60a5fa}.l4{color:#fbbf24}.l5{color:#f87171}
.le{color:#f87171}.lw{color:#fbbf24}.ln{color:#22d3ee}
.tbtn{font-size:.78rem;color:#555;text-decoration:none;background:#1e1e3a;border:1px solid #252550;padding:.35rem .9rem;border-radius:6px;transition:color .15s,border-color .15s}
.tbtn:hover{color:#a78bfa;border-color:#a78bfa}
.tbtn.active{color:#a78bfa;border-color:#a78bfa}
]]

local SETTINGS_CSS = [[
.settings-form{max-width:600px}
.setting{background:#13132b;border:1px solid #252550;border-radius:10px;padding:1.2rem 1.5rem;margin-bottom:1rem;display:flex;align-items:center;gap:1.2rem}
.setting-info{flex:1}
.setting-name{font-weight:600;font-size:.92rem;margin-bottom:.2rem}
.setting-desc{font-size:.78rem;color:#666;line-height:1.4}
.setting-source{font-size:.7rem;color:#444;margin-top:.3rem;font-style:italic}
.toggle{position:relative;width:44px;height:24px;flex-shrink:0}
.toggle input{opacity:0;width:0;height:0}
.toggle .slider{position:absolute;inset:0;background:#1e1e3a;border:1px solid #252550;border-radius:12px;cursor:pointer;transition:background .2s}
.toggle .slider::before{content:'';position:absolute;width:18px;height:18px;left:2px;bottom:2px;background:#555;border-radius:50%;transition:transform .2s,background .2s}
.toggle input:checked+.slider{background:#6d28d9;border-color:#7c3aed}
.toggle input:checked+.slider::before{transform:translateX(20px);background:#fff}
.save-btn{margin-top:1.5rem;background:#6d28d9;border:none;border-radius:8px;padding:.7rem 2rem;color:#fff;font-size:.88rem;font-weight:600;cursor:pointer;transition:background .15s;font-family:inherit}
.save-btn:hover{background:#7c3aed}
.input-field{background:#0d0d1a;border:1px solid #252550;border-radius:6px;padding:.5rem .8rem;color:#ddd;font-size:.85rem;outline:none;width:80px;text-align:center;font-family:inherit;transition:border-color .15s}
.input-field:focus{border-color:#a78bfa}
.section-title{font-size:.82rem;color:#555;text-transform:uppercase;letter-spacing:.05em;margin:1.5rem 0 .8rem;font-weight:500}
.section-title:first-child{margin-top:0}
]]

local LOGIN_CSS = [[
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0d0d1a;color:#ddd;min-height:100vh;display:flex;align-items:center;justify-content:center}
.login-card{background:#13132b;border:1px solid #252550;border-radius:12px;padding:2.5rem 2rem;width:100%;max-width:360px}
.login-card h1{font-size:1.2rem;color:#a78bfa;margin-bottom:.3rem}
.login-card .sub{font-size:.82rem;color:#555;margin-bottom:2rem}
label{display:block;font-size:.8rem;color:#888;margin-bottom:.4rem}
input[type=password]{width:100%;background:#0d0d1a;border:1px solid #252550;border-radius:6px;padding:.65rem .9rem;color:#ddd;font-size:.9rem;outline:none;transition:border-color .15s}
input[type=password]:focus{border-color:#a78bfa}
.login-btn{margin-top:1.2rem;width:100%;background:#6d28d9;border:none;border-radius:6px;padding:.7rem;color:#fff;font-size:.9rem;font-weight:600;cursor:pointer;transition:background .15s}
.login-btn:hover{background:#7c3aed}
.err{margin-top:1rem;background:#2a1a1a;border:1px solid #5a1a1a;border-radius:6px;padding:.6rem .9rem;font-size:.82rem;color:#f87171}
]]

local RESULT_CSS = [[
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0d0d1a;color:#ddd;min-height:100vh;display:flex;align-items:center;justify-content:center}
.result-card{background:#13132b;border:1px solid #252550;border-radius:12px;padding:2.5rem 2rem;width:100%;max-width:420px}
.result-card h1{font-size:1.1rem;color:#a78bfa;margin-bottom:1.2rem}
.result-card .field{margin-bottom:1rem}
.result-card .field label{font-size:.78rem;color:#666;display:block;margin-bottom:.3rem}
.result-card .field .val{background:#0d0d1a;border:1px solid #252550;border-radius:6px;padding:.6rem .9rem;font-family:'SF Mono',Monaco,Consolas,monospace;font-size:.9rem;color:#4ade80;word-break:break-all;user-select:all}
.result-card .back{display:inline-block;margin-top:1.2rem;font-size:.85rem;color:#a78bfa;text-decoration:none}
.result-card .back:hover{text-decoration:underline}
.result-card .warn{font-size:.78rem;color:#fbbf24;margin-top:.8rem;line-height:1.5}
]]

-- ── Page fragments ───────────────────────────────────────────────────────

local function page_open(title, extra_css, extra_head)
    return '<!DOCTYPE html>\n<html lang="en"><head><meta charset="utf-8">'
        .. '<meta name="viewport" content="width=device-width,initial-scale=1">'
        .. (extra_head or '')
        .. '<title>' .. esc(title) .. '</title><style>'
        .. COMMON_CSS .. (extra_css or '')
        .. '</style></head><body>'
end

local function nav_html(active)
    local p = {}
    p[#p+1] = '<header><div class="hdr-top"><div><h1>&#128218; KOReader Sync</h1>'
    p[#p+1] = '<div class="sub">Admin Dashboard</div></div>'
    if admin_password() then
        p[#p+1] = '<a href="/admin/logout" class="logout">Sign out</a>'
    end
    p[#p+1] = '</div><nav>'
    p[#p+1] = '<a href="/admin"' .. (active == "dashboard" and ' class="active"' or '') .. '>Dashboard</a>'
    p[#p+1] = '<a href="/admin/logs"' .. (active == "logs" and ' class="active"' or '') .. '>Logs</a>'
    p[#p+1] = '<a href="/admin/settings"' .. (active == "settings" and ' class="active"' or '') .. '>Settings</a>'
    p[#p+1] = '</nav></header>'
    return table.concat(p)
end

-- ── Render: login ────────────────────────────────────────────────────────

local function render_login(err_msg)
    local err_html = ""
    if err_msg then
        err_html = '<div class="err">' .. esc(err_msg) .. '</div>'
    end
    return '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">'
        .. '<meta name="viewport" content="width=device-width,initial-scale=1">'
        .. '<title>KOReader Sync \226\128\148 Login</title>'
        .. '<style>' .. LOGIN_CSS .. '</style></head><body>'
        .. '<div class="login-card"><h1>&#128218; KOReader Sync</h1>'
        .. '<div class="sub">Admin Dashboard</div>'
        .. '<form method="POST" action="/admin">'
        .. '<label for="pw">Password</label>'
        .. '<input type="password" id="pw" name="password" autofocus>'
        .. '<button type="submit" class="login-btn">Sign in</button>'
        .. err_html .. '</form></div></body></html>'
end

-- ── Render: password reset result ────────────────────────────────────────

local function render_reset_result(username, new_password)
    return '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">'
        .. '<meta name="viewport" content="width=device-width,initial-scale=1">'
        .. '<title>Password Reset</title>'
        .. '<style>' .. RESULT_CSS .. '</style></head><body>'
        .. '<div class="result-card">'
        .. '<h1>Password Reset</h1>'
        .. '<div class="field"><label>Username</label><div class="val">' .. esc(username) .. '</div></div>'
        .. '<div class="field"><label>New Password</label><div class="val">' .. esc(new_password) .. '</div></div>'
        .. '<div class="warn">Save this password now. It cannot be retrieved later.</div>'
        .. '<a href="/admin" class="back">&larr; Back to Dashboard</a>'
        .. '</div></body></html>'
end

-- ── Render: dashboard ────────────────────────────────────────────────────

local function render_dashboard(users, total_docs, flash_msg)
    local p = {}
    local function w(s) p[#p+1] = s end

    w(page_open("KOReader Sync \226\128\148 Admin", DASHBOARD_CSS))
    w(nav_html("dashboard"))
    w('<div class="bar">')
    w('<span>Users: <b>' .. #users .. '</b></span>')
    w('<span>Documents tracked: <b>' .. total_docs .. '</b></span>')
    w('<span>Generated: <b>' .. os.date("%Y-%m-%d %H:%M:%S") .. '</b></span>')
    w('</div><main>')

    if flash_msg then
        w('<div class="flash">' .. esc(flash_msg) .. '</div>')
    end

    if #users > 0 then
        w('<div class="search-wrap">')
        w('<input type="text" id="search" placeholder="Filter users or documents..." class="search-input">')
        w('</div>')
    end

    if #users == 0 then
        w('<div class="no-users"><h2>No users registered yet</h2><p>Devices will appear here once they sync.</p></div>')
    else
        for _, user in ipairs(users) do
            local initial = user.name:sub(1,1):upper()
            w('<div class="card" data-user="' .. esc(user.name) .. '"><div class="card-head">')
            w('<div class="avatar">' .. esc(initial) .. '</div>')
            w('<div class="uname">' .. esc(user.name) .. '</div>')
            w('<div class="badge">' .. #user.documents .. ' doc' .. (#user.documents == 1 and '' or 's') .. '</div>')
            w('<div class="user-actions">')
            w('<form method="POST" action="/admin/users/reset" style="display:inline">')
            w('<input type="hidden" name="username" value="' .. esc(user.name) .. '">')
            w('<button type="submit" class="btn-sm" onclick="return confirm(\'Reset password for ' .. esc(user.name) .. '?\')">Reset PW</button>')
            w('</form>')
            w('<form method="POST" action="/admin/users/delete" style="display:inline">')
            w('<input type="hidden" name="username" value="' .. esc(user.name) .. '">')
            w('<button type="submit" class="btn-sm btn-del" onclick="return confirm(\'Delete ' .. esc(user.name) .. ' and ALL their data?\')">Delete</button>')
            w('</form>')
            w('</div></div>')

            if #user.documents == 0 then
                w('<div class="empty-docs">No documents synced yet.</div>')
            else
                w('<table><thead><tr>')
                w('<th>Document</th><th>Progress</th><th>Device</th><th>Last Sync</th>')
                w('</tr></thead><tbody>')
                for _, doc in ipairs(user.documents) do
                    local pi = pct_bar(doc.percentage)
                    w('<tr>')
                    w('<td><div class="docname">' .. esc(doc.name) .. '</div></td>')
                    w('<td><div class="prog-wrap"><div class="prog-bg"><div class="prog-fill" style="width:' .. pi .. '%"></div></div><span class="pct">' .. pi .. '%</span></div></td>')
                    w('<td><div class="device">' .. esc(doc.device) .. '</div>')
                    if doc.device_id and doc.device_id ~= "" then
                        w('<div class="devid">' .. esc(doc.device_id) .. '</div>')
                    end
                    w('</td>')
                    w('<td><span class="ts">' .. fmt_time(doc.timestamp) .. '</span></td>')
                    w('</tr>')
                end
                w('</tbody></table>')
            end
            w('</div>')
        end
    end

    w([[<script>
var s=document.getElementById('search');
if(s)s.addEventListener('input',function(e){
var q=e.target.value.toLowerCase();
document.querySelectorAll('.card').forEach(function(c){
c.style.display=c.textContent.toLowerCase().indexOf(q)!==-1?'':'none';
});
});
</script>]])
    w('</main></body></html>')
    return table.concat(p)
end

-- ── Render: logs ─────────────────────────────────────────────────────────

local function access_class(line)
    local status = line:match('" (%d%d%d) ')
    if not status then return "" end
    local c = tonumber(status:sub(1,1))
    if c == 5 then return " l5" end
    if c == 4 then return " l4" end
    if c == 3 then return " l3" end
    if c == 2 then return " l2" end
    return ""
end

local function error_class(line)
    local level = line:match("%[(%a+)%]")
    if not level then return "" end
    if level == "error" or level == "crit" or level == "alert" or level == "emerg" then return " le" end
    if level == "warn" then return " lw" end
    if level == "notice" then return " ln" end
    return ""
end

local function render_logs(access, applog, auto_refresh)
    local p = {}
    local function w(s) p[#p+1] = s end

    local extra_head = ""
    if auto_refresh then
        extra_head = '<meta http-equiv="refresh" content="' .. auto_refresh .. '">'
    end

    w(page_open("KOReader Sync \226\128\148 Logs", LOGS_CSS, extra_head))
    w(nav_html("logs"))
    w('<main>')

    w('<div class="log-controls">')
    if auto_refresh then
        w('<a href="/admin/logs" class="tbtn active">&#9646;&#9646; Pause</a>')
        w('<span style="font-size:.78rem;color:#4ade80">Auto-refreshing every ' .. auto_refresh .. 's</span>')
    else
        w('<a href="/admin/logs?auto=5" class="tbtn">&#9654; Auto-refresh</a>')
        w('<a href="/admin/logs" class="tbtn">&#8635; Refresh</a>')
    end
    w('</div>')

    -- Access log
    w('<div class="log-section"><h2>Access Log <span class="cnt">' .. #access .. ' lines</span></h2>')
    w('<div class="log-box">')
    for i = #access, 1, -1 do
        w('<div class="ll' .. access_class(access[i]) .. '">' .. esc(access[i]) .. '</div>')
    end
    w('</div></div>')

    -- Application / error log
    w('<div class="log-section"><h2>Application Log <span class="cnt">' .. #applog .. ' lines</span></h2>')
    w('<div class="log-box">')
    for i = #applog, 1, -1 do
        w('<div class="ll' .. error_class(applog[i]) .. '">' .. esc(applog[i]) .. '</div>')
    end
    w('</div></div>')

    w('</main></body></html>')
    return table.concat(p)
end

-- ── Settings helpers ─────────────────────────────────────────────────────

local SETTINGS_DEFS = {
    {
        key = "user_registration",
        name = "User Registration",
        desc = "Allow new users to register via the KOReader client.",
        type = "bool",
        default = "true",
        env_var = "ENABLE_USER_REGISTRATION",
        env_true = { ["true"] = true, ["1"] = true },
    },
    {
        key = "rate_limit",
        name = "Rate Limit (req/sec)",
        desc = "Maximum API requests per second per IP address. Requires container restart to take effect.",
        type = "number",
        default = "10",
    },
    {
        key = "log_lines",
        name = "Log Lines to Display",
        desc = "Number of log lines shown in the Logs tab.",
        type = "number",
        default = "200",
    },
}

local function get_setting(redis, def)
    local val = redis:get("settings:" .. def.key)
    if val and val ~= null then return val end
    if def.env_var then
        local env = os.getenv(def.env_var)
        if env then
            if def.type == "bool" then
                return (def.env_true and def.env_true[env]) and "true" or "false"
            end
            return env
        end
    end
    return def.default or "false"
end

local function render_settings(settings_values, flash_msg)
    local p = {}
    local function w(s) p[#p+1] = s end

    w(page_open("KOReader Sync \226\128\148 Settings", SETTINGS_CSS))
    w(nav_html("settings"))
    w('<main>')

    if flash_msg then
        w('<div class="flash">' .. esc(flash_msg) .. '</div>')
    end

    w('<form method="POST" action="/admin/settings" class="settings-form">')
    w('<div class="section-title">Server</div>')

    for _, def in ipairs(SETTINGS_DEFS) do
        local val = settings_values[def.key]
        w('<div class="setting">')
        w('<div class="setting-info">')
        w('<div class="setting-name">' .. esc(def.name) .. '</div>')
        w('<div class="setting-desc">' .. esc(def.desc) .. '</div>')
        if def.env_var then
            local env = os.getenv(def.env_var)
            if env then
                w('<div class="setting-source">Default from env: ' .. esc(def.env_var) .. '=' .. esc(env) .. '</div>')
            end
        end
        w('</div>')

        if def.type == "bool" then
            local checked = val == "true" and " checked" or ""
            w('<label class="toggle">')
            w('<input type="hidden" name="' .. esc(def.key) .. '" value="false">')
            w('<input type="checkbox" name="' .. esc(def.key) .. '" value="true"' .. checked .. '>')
            w('<span class="slider"></span></label>')
        elseif def.type == "number" then
            w('<input type="number" name="' .. esc(def.key) .. '" value="' .. esc(val) .. '" class="input-field" min="1">')
        end

        w('</div>')
    end

    w('<button type="submit" class="save-btn">Save Settings</button>')
    w('</form>')
    w('</main></body></html>')
    return table.concat(p)
end

-- ── Controller actions ───────────────────────────────────────────────────

function AdminController:login()
    local pwd = admin_password()
    if not pwd then
        return ngx.redirect("/admin", 302)
    end
    local args = ngx.ctx.form_args
    if args and args.password == pwd then
        set_auth_cookie(pwd)
        return ngx.redirect("/admin", 302)
    end
    ngx.log(ngx.WARN, "admin login failed from ", ngx.var.remote_addr)
    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.say(render_login("Incorrect password."))
    return ngx.exit(200)
end

function AdminController:logout()
    clear_auth_cookie()
    return ngx.redirect("/admin", 302)
end

function AdminController:dashboard()
    if not admin_password() then
        ngx.header.content_type = "text/html; charset=utf-8"
        ngx.say(render_login("Admin dashboard is disabled. Set the ADMIN_PASSWORD environment variable to enable it."))
        return ngx.exit(403)
    end
    if not is_authenticated() then
        ngx.header.content_type = "text/html; charset=utf-8"
        ngx.say(render_login(nil))
        return ngx.exit(200)
    end

    local redis = Redis:new()
    if not redis then
        ngx.status = 503
        ngx.header.content_type = "text/plain"
        ngx.say("Redis unavailable")
        return ngx.exit(503)
    end

    local user_keys = redis:keys("user:*:key")
    local users = {}
    local total_docs = 0

    if type(user_keys) == "table" then
        for _, ukey in ipairs(user_keys) do
            local username = ukey:match("^user:(.+):key$")
            if username then
                local doc_keys = redis:keys("user:" .. username .. ":document:*")
                local documents = {}
                if type(doc_keys) == "table" then
                    for _, dkey in ipairs(doc_keys) do
                        local docname = dkey:match(":document:(.+)$")
                        if docname then
                            local res = redis:hmget(dkey, "percentage", "progress", "device", "device_id", "timestamp")
                            if type(res) == "table" then
                                documents[#documents+1] = {
                                    name       = docname,
                                    percentage = val(res[1]) or 0,
                                    progress   = val(res[2]) or "",
                                    device     = val(res[3]) or "",
                                    device_id  = val(res[4]) or "",
                                    timestamp  = val(res[5]),
                                }
                            end
                        end
                    end
                end
                table.sort(documents, function(a, b)
                    return (tonumber(a.timestamp) or 0) > (tonumber(b.timestamp) or 0)
                end)
                total_docs = total_docs + #documents
                users[#users+1] = { name = username, documents = documents }
            end
        end
    end

    table.sort(users, function(a, b) return a.name < b.name end)

    local flash_raw = ngx.var.arg_msg
    local flash = flash_raw and ngx.unescape_uri(flash_raw) or nil
    Redis.release()
    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.say(render_dashboard(users, total_docs, flash))
    return ngx.exit(200)
end

function AdminController:logs()
    if not is_authenticated() then
        return ngx.redirect("/admin", 302)
    end

    local redis = Redis:new()
    local max_lines = 200
    if redis then
        local v = redis:get("settings:log_lines")
        if v and v ~= null then max_lines = tonumber(v) or 200 end
        Redis.release()
    end

    local access = tail_file(log_path("access"), max_lines)
    local applog = tail_file(log_path("error"), max_lines)
    local auto = tonumber(ngx.var.arg_auto)
    if auto then
        auto = math.max(3, math.min(60, auto))
    end

    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.say(render_logs(access, applog, auto))
    return ngx.exit(200)
end

function AdminController:delete_user()
    if not is_authenticated() then
        return ngx.redirect("/admin", 302)
    end

    local args = ngx.ctx.form_args
    local username = args and args.username
    if not username or username == "" then
        return ngx.redirect("/admin?msg=No+username+provided", 302)
    end

    local redis = Redis:new()
    if not redis then
        return ngx.redirect("/admin?msg=Redis+unavailable", 302)
    end

    redis:del("user:" .. username .. ":key")
    local doc_keys = redis:keys("user:" .. username .. ":document:*")
    if type(doc_keys) == "table" then
        for _, k in ipairs(doc_keys) do
            redis:del(k)
        end
    end

    ngx.log(ngx.NOTICE, "admin deleted user: ", username, " from ", ngx.var.remote_addr)
    Redis.release()
    return ngx.redirect("/admin?msg=User+'" .. ngx.escape_uri(username) .. "'+deleted", 302)
end

function AdminController:reset_password()
    if not is_authenticated() then
        return ngx.redirect("/admin", 302)
    end

    local args = ngx.ctx.form_args
    local username = args and args.username
    if not username or username == "" then
        return ngx.redirect("/admin?msg=No+username+provided", 302)
    end

    local redis = Redis:new()
    if not redis then
        return ngx.redirect("/admin?msg=Redis+unavailable", 302)
    end

    local user_key = "user:" .. username .. ":key"
    local exists = redis:get(user_key)
    if not exists or exists == null then
        Redis.release()
        return ngx.redirect("/admin?msg=User+not+found", 302)
    end

    local new_pw = random_password()
    redis:set(user_key, hash_password(new_pw))

    ngx.log(ngx.NOTICE, "admin reset password for: ", username, " from ", ngx.var.remote_addr)
    Redis.release()

    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.say(render_reset_result(username, new_pw))
    return ngx.exit(200)
end

function AdminController:settings()
    if not is_authenticated() then
        return ngx.redirect("/admin", 302)
    end

    local redis = Redis:new()
    if not redis then
        ngx.status = 503
        ngx.header.content_type = "text/plain"
        ngx.say("Redis unavailable")
        return ngx.exit(503)
    end

    local values = {}
    for _, def in ipairs(SETTINGS_DEFS) do
        values[def.key] = get_setting(redis, def)
    end

    local flash_raw = ngx.var.arg_msg
    local flash = flash_raw and ngx.unescape_uri(flash_raw) or nil
    Redis.release()
    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.say(render_settings(values, flash))
    return ngx.exit(200)
end

function AdminController:save_settings()
    if not is_authenticated() then
        return ngx.redirect("/admin", 302)
    end

    local args = ngx.ctx.form_args
    if not args then
        return ngx.redirect("/admin/settings?msg=No+data+received", 302)
    end

    local redis = Redis:new()
    if not redis then
        return ngx.redirect("/admin/settings?msg=Redis+unavailable", 302)
    end

    for _, def in ipairs(SETTINGS_DEFS) do
        local val = args[def.key]
        if type(val) == "table" then val = val[#val] end
        if val then
            if def.type == "number" then
                val = tostring(tonumber(val) or def.default)
            end
            redis:set("settings:" .. def.key, val)
        end
    end

    ngx.log(ngx.NOTICE, "admin updated settings from ", ngx.var.remote_addr)
    Redis.release()
    return ngx.redirect("/admin/settings?msg=Settings+saved", 302)
end

return AdminController
