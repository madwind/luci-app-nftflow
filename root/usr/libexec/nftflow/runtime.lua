#!/usr/bin/lua
-- SPDX-License-Identifier: Apache-2.0
-- NftFlow process/runtime controller. Configuration, firewall, routing and updates are separate modules.

local jsonc = require "luci.jsonc"
local nixio = require "nixio"
local nixio_fs = require "nixio.fs"

local RUNTIME = "/var/run/nftflow"
local PID_FILE = RUNTIME .. "/xray.pid"
local STATE_FILE = RUNTIME .. "/state.json"
local APPLIED_CONFIG = RUNTIME .. "/config.applied.yaml"
local FIREWALL_CTL = "/usr/libexec/nftflow/firewall.lua"
local ROUTING_CTL = "/usr/libexec/nftflow/routing.lua"
local STOP_UPDATE = "/usr/libexec/nftflow/stop-update.lua"
local sequence = 0

local function encode(value)
    if jsonc.stringify then return jsonc.stringify(value) end
    return jsonc.encode(value)
end
local function decode(value)
    local decoder = jsonc.parse or jsonc.decode
    local ok, result = pcall(decoder, value)
    return ok and result or nil
end
local function trim(value) return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function shellquote(value) return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'" end
local function exec_capture(command)
    local pipe = io.popen(command .. " 2>&1")
    if not pipe then return false, "unable to execute command" end
    local output = pipe:read("*a") or ""
    local ok, reason, code = pipe:close()
    if ok == true or code == 0 then return true, output end
    return false, trim(output ~= "" and output or (reason or "command failed"))
end
local function exec_quiet(command)
    local ok = os.execute(command .. " >/dev/null 2>&1")
    return ok == true or ok == 0
end
local function mkdirp(path)
    if nixio_fs and nixio_fs.mkdirr then return nixio_fs.mkdirr(path) end
    return exec_quiet("mkdir -p " .. shellquote(path))
end
local function dirname(path) return tostring(path):match("^(.*)/[^/]*$") or "." end
local function read_file(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local value = file:read("*a")
    file:close()
    return value
end
local function temporary_path(path)
    sequence = sequence + 1
    local seconds, microseconds = nixio.gettimeofday()
    return string.format("%s.tmp.%d.%d.%d.%d", path, nixio.getpid(), seconds, microseconds or 0, sequence)
end
local function write_atomic(path, value, mode)
    if not mkdirp(dirname(path)) then return false, "cannot create " .. dirname(path) end
    local temporary = temporary_path(path)
    local file, err = io.open(temporary, "w")
    if not file then return false, err or "cannot open temporary file" end
    if not file:write(value) then file:close(); os.remove(temporary); return false, "cannot write temporary file" end
    local closed, close_error = file:close()
    if not closed then os.remove(temporary); return false, close_error or "cannot close temporary file" end
    if mode then exec_quiet("chmod " .. tostring(mode) .. " " .. shellquote(temporary)) end
    if not os.rename(temporary, path) then os.remove(temporary); return false, "cannot replace " .. path end
    if mode then exec_quiet("chmod " .. tostring(mode) .. " " .. shellquote(path)) end
    return true
end
local function uci_get(option, default)
    local ok, output = exec_capture("/sbin/uci -q get nftflow.main." .. option)
    output = trim(output)
    return ok and output ~= "" and output or default
end
local function bool(value) return value == true or value == 1 or value == "1" or value == "true" or value == "yes" or value == "on" end

local function main_config()
    local gid = tonumber(uci_get("run_gid", "23333"))
    if not gid or gid < 1 or gid > 65535 or gid % 1 ~= 0 then error("run_gid must be between 1 and 65535") end
    local nofile = tonumber(uci_get("nofile", "65536")) or 65536
    if nofile < 1024 then error("nofile must be at least 1024") end
    return {
        enabled = bool(uci_get("enabled", "0")),
        xray_bin = uci_get("xray_bin", "/usr/bin/xray"),
        config_file = uci_get("config_file", "/etc/nftflow/config.yaml"),
        asset_dir = uci_get("asset_dir", "/usr/share/xray"),
        run_gid = gid,
        run_group = uci_get("run_group", "nftflow"),
        nofile = nofile
    }
end

local RUNTIME_STATES = { starting = true, ready = true, stopping = true, stopped = true, failed = true }
local function read_state()
    local raw = read_file(STATE_FILE)
    local state = raw and decode(raw) or nil
    return type(state) == "table" and state or nil
end
local function write_state(state, pid, message)
    if not RUNTIME_STATES[state] then return nil, "invalid runtime state: " .. tostring(state) end
    if pid ~= nil and trim(pid) == "" then pid = nil end
    if pid ~= nil then
        pid = tonumber(pid)
        if not pid or pid < 2 or pid % 1 ~= 0 then return nil, "invalid runtime PID" end
    end
    if not mkdirp(RUNTIME) then return nil, "cannot create " .. RUNTIME end
    local previous = read_state() or {}
    local now = os.time()
    local result = { state = state, updated = now, restart_count = tonumber(previous.restart_count) or 0 }
    if state == "starting" then
        result.pid = pid
        result.started = now
        if previous.state == "failed" or previous.state == "ready" or previous.state == "starting" then result.restart_count = result.restart_count + 1 end
    elseif state == "ready" or state == "stopping" then
        result.pid = pid or tonumber(previous.pid)
        result.started = tonumber(previous.started)
    elseif state == "failed" then
        result.pid = pid
        result.started = tonumber(previous.started)
        result.finished = now
    else
        result.finished = now
    end
    if message and tostring(message) ~= "" then result.error = tostring(message) end
    if (state == "starting" or state == "ready" or state == "stopping") and result.pid then
        local saved, err = write_atomic(PID_FILE, tostring(result.pid) .. "\n", 600)
        if not saved then return nil, err end
    else
        os.remove(PID_FILE)
    end
    local saved, err = write_atomic(STATE_FILE, encode(result) .. "\n", 600)
    if not saved then return nil, err end
    return result
end

local function canonical(path)
    local ok, output = exec_capture("readlink -f " .. shellquote(path))
    return ok and trim(output) or path
end
local function process_pid(binary)
    local pid = tonumber(trim(read_file(PID_FILE)))
    if not pid or pid < 2 or pid % 1 ~= 0 then return nil end
    if not exec_quiet("kill -0 " .. tostring(pid)) then return nil end
    local ok, actual = exec_capture("readlink -f /proc/" .. tostring(pid) .. "/exe")
    if not ok or trim(actual) ~= trim(canonical(binary)) then return nil end
    return pid
end
local function terminate(pid)
    pid = tonumber(pid)
    if not pid or pid < 2 or not exec_quiet("kill -0 " .. tostring(math.floor(pid))) then return true end
    exec_quiet("kill -TERM " .. tostring(math.floor(pid)))
    for _ = 1, 5 do
        if not exec_quiet("kill -0 " .. tostring(math.floor(pid))) then return true end
        exec_quiet("sleep 1")
    end
    exec_quiet("kill -KILL " .. tostring(math.floor(pid)))
    return not exec_quiet("kill -0 " .. tostring(math.floor(pid)))
end

local function parse_result(output)
    local last
    for line in tostring(output or ""):gmatch("[^\r\n]+") do if trim(line) ~= "" then last = trim(line) end end
    return last and decode(last) or nil
end
local function run_lua(path, args)
    local command = "/usr/bin/lua " .. shellquote(path)
    for _, value in ipairs(args or {}) do command = command .. " " .. shellquote(value) end
    local ok, output = exec_capture(command)
    local result = parse_result(output)
    if type(result) ~= "table" then return { ok = false, error = ok and "command returned invalid JSON" or output } end
    return result
end

local function remove_temporary_files()
    if not mkdirp(RUNTIME) then return false, "cannot create " .. RUNTIME end
    for _, pattern in ipairs({
        RUNTIME .. "/config-check*.yaml*",
        RUNTIME .. "/firewall-check*.nft*",
        RUNTIME .. "/firewall-apply*.nft*",
        RUNTIME .. "/*.nftflow-result.*",
        RUNTIME .. "/*.nftflow-download.*",
        RUNTIME .. "/*.tmp.*"
    }) do exec_quiet("rm -f " .. pattern) end
    exec_quiet("find " .. shellquote(RUNTIME) .. " -maxdepth 1 -type d -name 'rpc-*' -exec rm -rf {} \\;")
    return true
end

local function prepare()
    mkdirp(RUNTIME)
    mkdirp("/etc/nftflow")
    mkdirp("/var/log/nftflow")
    local main = main_config()
    if not process_pid(main.xray_bin) then
        remove_temporary_files()
        local state = read_state()
        if state and (state.state == "starting" or state.state == "ready" or state.state == "stopping") then
            write_state("failed", nil, "stale runtime state cleaned during prepare")
        end
    end
    return { ok = true }
end

local function service_sync()
    local enabled = bool(uci_get("enabled", "0"))
    local action = enabled and "enable" or "disable"
    local ok, output = exec_capture("/etc/init.d/nftflow " .. action)
    if not ok then return { ok = false, enabled = enabled, action = action, error = trim(output) } end
    local verified = exec_quiet("/etc/init.d/nftflow enabled")
    if verified ~= enabled then return { ok = false, enabled = enabled, action = action, error = "service boot state did not match nftflow.main.enabled" } end
    return { ok = true, enabled = enabled, action = action }
end

local function firewall_active()
    local ok, output = exec_capture("nft list tables")
    if not ok then return false end
    for line in (output .. "\n"):gmatch("(.-)\n") do
        if trim(line):match("^table%s+%S+%s+nftflow$") then return true end
    end
    return false
end
local function routing_status()
    local result = run_lua(ROUTING_CTL, { "status" })
    if result.ok ~= true then return { active = false, ipv4 = false, ipv6 = false } end
    return result
end
local function process_identity(pid)
    if not pid then return nil, nil end
    local status = read_file("/proc/" .. tostring(pid) .. "/status") or ""
    return tonumber(status:match("\nUid:%s*(%d+)")), tonumber(status:match("\nGid:%s*(%d+)"))
end
local function procd_state()
    local ok, output = exec_capture("ubus -S call service list '{\"name\":\"nftflow\"}'")
    local parsed = ok and decode(output) or nil
    local service = type(parsed) == "table" and parsed.nftflow or nil
    if type(service) ~= "table" or type(service.instances) ~= "table" then return { managed = false, running = false } end
    for _, instance in pairs(service.instances) do
        if type(instance) == "table" and (instance.running == true or instance.running == 1) then return { managed = true, running = true } end
    end
    return { managed = true, running = false }
end

local function status()
    local main = main_config()
    local pid = process_pid(main.xray_bin)
    local runtime = read_state() or {}
    local state = runtime.state
    if not RUNTIME_STATES[state] then state = pid and "starting" or "stopped" end
    if pid and (state == "failed" or state == "stopped") then state = "starting" end
    if not pid and (state == "starting" or state == "ready") then state = "failed" end
    if not pid and state == "stopping" then state = "stopped" end
    local uid, gid = process_identity(pid)
    local routing = routing_status()
    local config = read_file(main.config_file)
    local version_ok, version_output = exec_capture("apk list --installed luci-app-nftflow 2>/dev/null")
    local app_version = version_ok and trim(version_output):match("^luci%-app%-nftflow%-([^%s]+)") or nil
    local procd = procd_state()
    local started = tonumber(runtime.started)
    return {
        ok = true,
        running = pid ~= nil,
        process = pid ~= nil,
        procd_managed = procd.managed,
        procd_running = procd.running,
        runtime_state = state,
        state_error = runtime.error,
        app_version = app_version,
        pid = pid,
        uid = uid,
        gid = gid,
        uid_ok = pid ~= nil and uid == 0 or nil,
        expected_gid = main.run_gid,
        gid_ok = pid ~= nil and gid == main.run_gid or nil,
        enabled = main.enabled,
        uptime = pid and started and math.max(0, os.time() - started) or nil,
        restart_count = tonumber(runtime.restart_count) or 0,
        config_file = main.config_file,
        config_bytes = config and #config or 0,
        firewall_active = firewall_active(),
        route_active = routing.active == true,
        route_ipv6 = routing.ipv6 == true
    }
end

local function action(name)
    if name ~= "start" and name ~= "stop" and name ~= "restart" and name ~= "reload" then return { ok = false, error = "unsupported service action" } end
    local force = name == "start" or name == "restart"
    local init_action = name == "reload" and "restart" or name
    local prefix = force and "NFTFLOW_FORCE_START=1 " or ""
    local ok, output = exec_capture(prefix .. "/etc/init.d/nftflow " .. shellquote(init_action))
    local current = status()
    if not ok then return { ok = false, action = name, init_action = init_action, accepted = false, detail = trim(output), status = current } end
    return { ok = true, action = name, init_action = init_action, accepted = true, runtime_state = current.runtime_state, detail = trim(output), status = current }
end

local function cleanup()
    local main = main_config()
    local pid = process_pid(main.xray_bin)
    if pid and not terminate(pid) then return { ok = false, error = "cannot stop Xray process " .. tostring(pid) } end
    for _, kind in ipairs({ "geoip", "geosite" }) do run_lua(STOP_UPDATE, { kind }) end
    local firewall = run_lua(FIREWALL_CTL, { "firewall", "off" })
    if firewall.ok == false then return firewall end
    local routing = run_lua(ROUTING_CTL, { "route", "del" })
    if routing.ok == false then return routing end
    remove_temporary_files()
    os.remove(APPLIED_CONFIG)
    os.remove(STATE_FILE)
    os.remove(PID_FILE)
    return { ok = true, cleaned = true }
end

local function dispatch(command, args)
    if command == "prepare" then return prepare() end
    if command == "service-sync" then return service_sync() end
    if command == "cleanup" then return cleanup() end
    if command == "state" then
        local state, err = write_state(args[1] or "", args[2], args[3])
        return state and { ok = true, state = state } or { ok = false, error = err }
    end
    if command == "status" then return status() end
    if command == "reload" then return action("reload") end
    if command == "action" then return action(args[1]) end
    return { ok = false, error = "unsupported runtime command: " .. tostring(command) }
end

local command, args = arg[1] or "", {}
for index = 2, #arg do args[#args + 1] = arg[index] end
local ok, result = pcall(dispatch, command, args)
local code = 0
if not ok then result, code = { ok = false, error = tostring(result) }, 1
elseif type(result) ~= "table" then result = { ok = true, result = result }
elseif result.ok == false then code = 1 end
io.write(encode(result) .. "\n")
os.exit(code)
