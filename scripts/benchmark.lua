-- Load driver and report for scripts/benchmark.sh.
--
-- Runs inside a server container under the OpenResty resty CLI, so the HTTP
-- port and redis are both on loopback and there is no container networking.
--
--     resty scripts/benchmark.lua prepare
--     resty scripts/benchmark.lua measure --endpoint put --duration 10
--     resty scripts/benchmark.lua report < runs.ndjson
--
-- measure writes one JSON object to stdout. report reads them back and writes
-- markdown.

local cjson = require "cjson"
local redis = require "resty.redis"
local ffi = require "ffi"

local USER = "bench"
local PASSWORD = "benchkey"
local DOCUMENT = "C1"
local PROGRESS = "/body/DocFragment[3]/body/p[9]"
local ACCEPT = "application/vnd.koreader.v1+json"
local HTTP_PORT = 17200 -- config/nginx.conf listens 1<port> for plain http
local REDIS_PORT = 6379
local REDIS_DB = 1 -- gin's production environment
local HEALTH_TIMEOUT = 180
local ERROR_BUDGET = 0.01

local ENDPOINTS = {
    { name = "put", method = "PUT", path = "/syncs/progress" },
    { name = "get", method = "GET", path = "/syncs/progress/" .. DOCUMENT },
}

local PUT_BODY = cjson.encode({
    document = DOCUMENT,
    progress = PROGRESS,
    percentage = 0.5,
    device = "bench",
    device_id = "D1",
})

local function fail(fmt, ...)
    io.stderr:write("benchmark: " .. string.format(fmt, ...) .. "\n")
    os.exit(1)
end

ffi.cdef [[
    typedef long time_t;
    struct timespec { time_t tv_sec; long tv_nsec; };
    int clock_gettime(int clk_id, struct timespec *tp);
]]

-- ngx.now() is cached and resolves to a millisecond, which is the order of the
-- latencies being measured.
local clock = ffi.new("struct timespec[1]")
local function now()
    ffi.C.clock_gettime(1, clock) -- CLOCK_MONOTONIC
    return tonumber(clock[0].tv_sec) + tonumber(clock[0].tv_nsec) / 1e9
end

-- ---------------------------------------------------------------------- http

local function request_text(method, path, body)
    return table.concat({
        method, " ", path, " HTTP/1.1\r\n",
        "Host: 127.0.0.1\r\n",
        "Accept: ", ACCEPT, "\r\n",
        "x-auth-user: ", USER, "\r\n",
        "x-auth-key: ", PASSWORD, "\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: ", body and #body or 0, "\r\n\r\n",
        body or "",
    })
end

local function read_response(sock)
    local line = sock:receive("*l")
    if not line then return nil end
    local status = tonumber(line:match("^HTTP/%d%.%d (%d%d%d)"))
    local length, chunked, keepalive = nil, false, true
    while true do
        local header = sock:receive("*l")
        if not header or header == "" then break end
        local key, value = header:match("^([^:]+):%s*(.-)%s*$")
        key = key and key:lower()
        if key == "content-length" then
            length = tonumber(value)
        elseif key == "transfer-encoding" and value:lower():find("chunked", 1, true) then
            chunked = true
        elseif key == "connection" and value:lower():find("close", 1, true) then
            keepalive = false
        end
    end

    local body = {}
    if chunked then
        while true do
            local size = sock:receive("*l")
            local n = tonumber((size or ""):match("^%x+") or "", 16)
            if not n or n == 0 then
                sock:receive("*l")
                break
            end
            body[#body + 1] = sock:receive(n)
            sock:receive("*l")
        end
    elseif length and length > 0 then
        body[1] = sock:receive(length)
    end
    return status, table.concat(body), keepalive
end

local function connect()
    local sock = ngx.socket.tcp()
    sock:settimeout(10000)
    if not sock:connect("127.0.0.1", HTTP_PORT) then return nil end
    return sock
end

local function request(method, path, body)
    local sock = connect()
    if not sock then return nil, "connection refused" end
    if not sock:send(request_text(method, path, body)) then
        sock:close()
        return nil, "send failed"
    end
    local status, text = read_response(sock)
    sock:close()
    return status, text
end

-- ---------------------------------------------------------------------- load

local function percentile(sorted, p)
    if #sorted == 0 then return 0 end
    local i = math.min(#sorted, math.floor(p / 100 * #sorted + 0.5))
    return sorted[math.max(i, 1)]
end

local function drive(method, path, body, seconds, conns)
    local payload = request_text(method, path, body)
    local deadline = now() + seconds
    local threads = {}

    for _ = 1, conns do
        threads[#threads + 1] = ngx.thread.spawn(function()
            local latencies, errors = {}, 0
            local sock = connect()
            while now() < deadline do
                local status, keepalive
                local started = now()
                if sock and sock:send(payload) then
                    status, _, keepalive = read_response(sock)
                end
                local elapsed = now() - started
                if status == 200 then
                    latencies[#latencies + 1] = elapsed * 1e6
                else
                    errors = errors + 1
                end
                -- nginx closes a keepalive connection after keepalive_requests.
                -- Reconnecting on its say-so is not a failed request.
                if status ~= 200 or not keepalive then
                    if sock then sock:close() end
                    sock = connect()
                end
            end
            if sock then sock:close() end
            return latencies, errors
        end)
    end

    local latencies, errors = {}, 0
    local started = now()
    for _, thread in ipairs(threads) do
        local ok, got, err = ngx.thread.wait(thread)
        if not ok then fail("load thread died: %s", tostring(got)) end
        for _, value in ipairs(got) do latencies[#latencies + 1] = value end
        errors = errors + err
    end
    local elapsed = now() - started

    table.sort(latencies)
    return {
        requests = #latencies,
        errors = errors,
        rps = elapsed > 0 and #latencies / elapsed or 0,
        p50 = percentile(latencies, 50),
        p95 = percentile(latencies, 95),
        p99 = percentile(latencies, 99),
    }
end

-- --------------------------------------------------------------------- redis

local function open_redis()
    local red = redis:new()
    red:set_timeout(5000)
    local ok, err = red:connect("127.0.0.1", REDIS_PORT)
    if not ok then fail("redis: %s", tostring(err)) end
    red:select(REDIS_DB)
    return red
end

local function commandstats(red)
    local text = red:info("commandstats")
    local stats = {}
    for line in tostring(text):gmatch("[^\r\n]+") do
        local name, calls = line:match("^cmdstat_([^:]+):calls=(%d+)")
        -- The driver shares this redis, so its own bookkeeping is not load.
        if name and not name:match("^info") and not name:match("^config") then
            stats[name] = tonumber(calls)
        end
    end
    return stats
end

-- ------------------------------------------------------------------- reading

local function parse_args(argv)
    local opts = {}
    local i = 1
    while i <= #argv do
        local key = argv[i]:match("^%-%-(.+)$")
        if not key then fail("unexpected argument %s", argv[i]) end
        opts[key:gsub("%-", "_")] = argv[i + 1]
        i = i + 2
    end
    return opts
end

local function endpoint_by_name(name)
    for _, e in ipairs(ENDPOINTS) do
        if e.name == name then return e end
    end
    fail("unknown endpoint %s", tostring(name))
end

-- ------------------------------------------------------------------ commands

local function cmd_prepare()
    local deadline = now() + HEALTH_TIMEOUT
    local last = "no answer"
    while now() < deadline do
        local status, text = request("GET", "/healthcheck")
        if status == 200 and text:gsub("%s", ""):find('"state":"OK"', 1, true) then
            -- Applied to both arms: a background save inside one measurement
            -- window would be charged to that arm alone.
            local red = open_redis()
            red:config("set", "save", "")
            red:config("set", "appendonly", "no")
            red:close()
            return
        end
        last = status and ("HTTP " .. status) or "no answer"
        ngx.sleep(1)
    end
    fail("never became healthy: %s", last)
end

local function cmd_measure(opts)
    local endpoint = endpoint_by_name(opts.endpoint)
    local body = endpoint.method == "PUT" and PUT_BODY or nil
    local duration = tonumber(opts.duration) or 10
    local warmup = tonumber(opts.warmup) or 3
    local conns = tonumber(opts.conns) or 2

    local red = open_redis()
    red:flushdb()
    for _, seed in ipairs({
        { "POST", "/users/create",
          cjson.encode({ username = USER, password = PASSWORD }), 201 },
        { "PUT", "/syncs/progress", PUT_BODY, 200 },
        { "GET", "/syncs/progress/" .. DOCUMENT, nil, 200 },
    }) do
        local status, text = request(seed[1], seed[2], seed[3])
        if status ~= seed[4] then
            fail("seeding %s %s returned %s: %s", seed[1], seed[2],
                tostring(status), tostring(text):sub(1, 200))
        end
    end

    drive(endpoint.method, endpoint.path, body, warmup, conns)
    red:config("resetstat")
    local before = commandstats(red)
    local result = drive(endpoint.method, endpoint.path, body, duration, conns)
    local after = commandstats(red)
    red:close()

    local ops, total = {}, 0
    for name, calls in pairs(after) do
        local delta = calls - (before[name] or 0)
        if delta > 0 then
            ops[name] = delta
            total = total + delta
        end
    end

    local n = result.requests + result.errors
    result.ops = ops
    result.ops_per_request = n > 0 and total / n or 0
    result.type = "run"
    result.arm = opts.arm
    result.rep = tonumber(opts.rep)
    result.endpoint = endpoint.name
    io.stderr:write(string.format(
        "rep %s  %-4s %-4s  rps=%7.1f  p50=%6.0fus  redis_ops/req=%5.2f  errors=%d\n",
        tostring(opts.rep), tostring(opts.arm), endpoint.name, result.rps,
        result.p50, result.ops_per_request, result.errors))
    print(cjson.encode(result))
end

-- -------------------------------------------------------------------- report

local function median(values)
    local sorted = {}
    for _, v in ipairs(values) do sorted[#sorted + 1] = v end
    table.sort(sorted)
    local n = #sorted
    if n == 0 then return 0 end
    if n % 2 == 1 then return sorted[(n + 1) / 2] end
    return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

local function field(runs, key)
    local values = {}
    for _, run in ipairs(runs) do values[#values + 1] = run[key] end
    return values
end

local function cmd_report()
    local meta, runs = nil, {}
    for line in io.read("*a"):gmatch("[^\n]+") do
        local ok, row = pcall(cjson.decode, line)
        if ok and row.type == "meta" then
            meta = row
        elseif ok and row.type == "run" then
            runs[row.arm] = runs[row.arm] or {}
            runs[row.arm][row.endpoint] = runs[row.arm][row.endpoint] or {}
            local into = runs[row.arm][row.endpoint]
            into[#into + 1] = row
        end
    end
    if not meta then fail("no run metadata on stdin") end

    local out = {}
    local function w(fmt, ...)
        out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    end
    local function of(arm, name) return runs[arm] and runs[arm][name] or {} end

    w("## Benchmark: `%s` vs `%s`", meta.base_ref, meta.head_ref)
    w("")
    w("| | ref | commit |")
    w("|---|---|---|")
    w("| base | `%s` | `%s` |", meta.base_ref, meta.base_sha:sub(1, 12))
    w("| head | `%s` | `%s` |", meta.head_ref, meta.head_sha:sub(1, 12))
    w("")
    w("%d repetitions of %ds at %d connections, %ds warmup discarded, arms "
        .. "interleaved.", meta.reps, meta.duration, meta.conns, meta.warmup)
    w("")

    w("### Redis commands per request")
    w("")
    w("Exact counts, not timings. Identical requests produce identical counts, "
        .. "so a change in this table is a real property of the code.")
    w("")
    w("| endpoint | base | head | change |")
    w("|---|---:|---:|---:|")
    for _, e in ipairs(ENDPOINTS) do
        local b = median(field(of("base", e.name), "ops_per_request"))
        local h = median(field(of("head", e.name), "ops_per_request"))
        w("| `%s %s` | %.2f | %.2f | %+.2f |", e.method, e.path, b, h, h - b)
    end
    w("")
    w("<details><summary>per command</summary>")
    w("")
    w("| endpoint | command | base | head |")
    w("|---|---|---:|---:|")
    for _, e in ipairs(ENDPOINTS) do
        local per, totals = {}, {}
        for _, arm in ipairs({ "base", "head" }) do
            totals[arm] = 0
            for _, run in ipairs(of(arm, e.name)) do
                totals[arm] = totals[arm] + run.requests + run.errors
                for name, calls in pairs(run.ops) do
                    per[name] = per[name] or {}
                    per[name][arm] = (per[name][arm] or 0) + calls
                end
            end
            if totals[arm] == 0 then totals[arm] = 1 end
        end
        local names = {}
        for name in pairs(per) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            w("| `%s` | `%s` | %.2f | %.2f |", e.method:lower(), name,
                (per[name].base or 0) / totals.base,
                (per[name].head or 0) / totals.head)
        end
    end
    w("")
    w("</details>")
    w("")

    w("### Latency and throughput")
    w("")
    w("Advisory. A shared runner drifts by more than most real changes, so read "
        .. "the paired column, which is head against base within the same "
        .. "repetition, and treat any range that crosses zero as no result.")
    w("")
    w("| endpoint | metric | base | head | paired, median (min..max) |")
    w("|---|---|---:|---:|---:|")
    for _, e in ipairs(ENDPOINTS) do
        local base, head = of("base", e.name), of("head", e.name)
        for _, metric in ipairs({
            { "p50", "us" }, { "p95", "us" }, { "p99", "us" }, { "rps", "req/s" },
        }) do
            local key, unit = metric[1], metric[2]
            local deltas, lo, hi = {}, math.huge, -math.huge
            for i = 1, math.min(#base, #head) do
                local b = base[i][key]
                local delta = b ~= 0 and (head[i][key] / b - 1) * 100 or 0
                deltas[#deltas + 1] = delta
                lo, hi = math.min(lo, delta), math.max(hi, delta)
            end
            w("| `%s %s` | %s | %.0f %s | %.0f %s | %+.1f%% (%+.1f..%+.1f) |",
                e.method, e.path, key,
                median(field(base, key)), unit, median(field(head, key)), unit,
                median(deltas), lo, hi)
        end
    end
    w("")

    local requests, errors = 0, 0
    for _, arm in ipairs({ "base", "head" }) do
        for _, e in ipairs(ENDPOINTS) do
            for _, run in ipairs(of(arm, e.name)) do
                requests = requests + run.requests + run.errors
                errors = errors + run.errors
            end
        end
    end
    w("%d requests, %d non-200 or failed.", requests, errors)

    io.write(table.concat(out, "\n"), "\n")
    io.stdout:flush()

    -- A timing never fails the run. A benchmark that could not serve its own
    -- requests measured nothing, and does.
    if requests > 0 and errors / requests > ERROR_BUDGET then
        io.stderr:write(string.format("%d of %d requests failed\n", errors, requests))
        os.exit(1)
    end
end

local command = arg[1]
local opts = parse_args({ unpack(arg, 2) })
if command == "prepare" then
    cmd_prepare()
elseif command == "measure" then
    cmd_measure(opts)
elseif command == "report" then
    cmd_report()
else
    fail("usage: benchmark.lua prepare|measure|report")
end
