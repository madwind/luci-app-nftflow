#!/usr/bin/lua
-- SPDX-License-Identifier: Apache-2.0
-- GeoData updater with explicit uclient-fetch diagnostics and cached checks.

local jsonc = require "luci.jsonc"
local nixio = require "nixio"
local nixio_fs = require "nixio.fs"
local geodata_version = dofile "/usr/libexec/nftflow/geodata-version.lua"

local RUNTIME = "/var/run/nftflow"
local LOG_DIR = "/var/log/nftflow"
local UCLIENT_FETCH = "/bin/uclient-fetch"
local CTL = "/usr/libexec/nftflow/nftflowctl"
local DEFAULT_GEOIP_URL = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
local DEFAULT_GEBSITE_URL = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
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

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shellquote(value)
    return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

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

local function read_file(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local value = file:read("*a")
    file:close()
    return value
end

local function mkdirp(path)
    if nixio_fs and nixio_fs.mkdirr then return nixio_fs.mkdirr(path) end
    return exec_quiet("mkdir -p " .. shellquote(path))
end

local function temporary_path(base)
    sequence = sequence + 1
    local seconds, microseconds = nixio.gettimeofday()
    return string.format("%s.tmp.%d.%d.%d.%d", base, nixio.getpid(), seconds, microseconds or 0, sequence)
end

local function write_atomic(path, value, mode)
    local temporary = temporary_path(path)
    local file, err = io.open(temporary, "w")
    if not file then return false, err or "cannot open temporary file" end
    if not file:write(value) then
        file:close()
        os.remove(temporary)
        return false, "cannot write temporary file"
    end
    local closed, close_error = file:close()
    if not closed then
        os.remove(temporary)
        return false, close_error or "cannot close temporary file"
    end
    if mode then exec_quiet("chmod " .. tostring(mode) .. " " .. shellquote(temporary)) end
    if not os.rename(temporary, path) then
        os.remove(temporary)
        return false, "cannot replace " .. path
    end
    return true
end

local function uci_get(option, default)
    local ok, output = exec_capture("/sbin/uci -q get nftflow.main." .. option)
    output = trim(output)
    return ok and output ~= "" and output or default
end

local function config(kind)
    local asset_dir = trim(uci_get("asset_dir", "/usr/share/xray"))
    if kind == "geoip" then
        return {
            kind = kind,
            path = trim(uci_get("geoip_file", asset_dir .. "/geoip.dat")),
            url = trim(uci_get("geoip_url", DEFAULT_GEOIP_URL))
        }
    elseif kind == "geosite" then
        return {
            kind = kind,
            path = trim(uci_get("geosite_file", asset_dir .. "/geosite.dat")),
            url = trim(uci_get("geosite_url", DEFAULT_GEBSITE_URL))
        }
    end
    return nil
end

local function asset_ready(kind)
    local asset = config(kind)
    local stat = asset and nixio_fs and nixio_fs.stat and nixio_fs.stat(asset.path) or nil
    return type(stat) == "table" and (tonumber(stat.size) or 0) >= 1024
end

local function dirname(path)
    return tostring(path):match("^(.*)/[^/]*$") or "."
end

local function state_path(kind)
    return RUNTIME .. "/geo-update-" .. kind .. ".json"
end

local function lock_path(kind)
    return RUNTIME .. "/geo-update-" .. kind .. ".lock"
end

local function save_state(kind, state)
    state.kind = kind
    return write_atomic(state_path(kind), encode(state) .. "\n", 600)
end

local function read_state(kind)
    local raw = read_file(state_path(kind))
    local value = raw and trim(raw) ~= "" and decode(raw) or nil
    if type(value) ~= "table" then value = { kind = kind, status = "idle" } end
    value.kind = kind
    if asset_ready(kind) then
        local installed = geodata_version.read(kind)
        if installed then
            value.local_version = value.local_version or installed
            value.source_version = value.source_version or installed
        end
    else
        value.local_version = nil
        value.source_version = nil
    end
    return value
end

local function remove_lock(kind)
    exec_quiet("rmdir " .. shellquote(lock_path(kind)))
end

local function process_alive(pid)
    pid = tonumber(pid)
    return pid and pid > 1 and exec_quiet("kill -0 " .. tostring(math.floor(pid)))
end

local function release_version(output)
    return tostring(output or ""):match("/releases/download/([^/%s]+)/")
end

local function operation_active(state)
    return state and (state.status == "starting" or state.status == "running") and process_alive(state.pid)
end

local function last_update_from_state(state)
    local value = tonumber(state and state.last_update)
    if value then return value end
    if state and state.updated == true then return tonumber(state.finished) end
    return nil
end

local function parse_ctl_result(output)
    local last
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        line = trim(line)
        if line ~= "" then last = line end
    end
    return last and decode(last) or nil
end

local function probe(kind)
    local ok, output = exec_capture("/bin/sh " .. shellquote(CTL) .. " geo check " .. shellquote(kind))
    local result = parse_ctl_result(output)
    if type(result) == "table" then return result end
    return { ok = false, kind = kind, error = ok and "GeoData check returned invalid JSON" or output }
end

local function apply_check(state, result)
    state.checked = os.time()
    state.check_ok = result.ok == true
    if result.ok == true then
        state.latest_version = result.remote_version
        state.update_available = result.update_available
        state.last_check_error = nil
        state.local_version = result.local_version or state.local_version or state.source_version
    else
        state.last_check_error = result.error or "GeoData check failed"
    end
end

local function check(kind)
    if not config(kind) then return { ok = false, kind = kind, error = "unsupported GeoData kind" } end
    if not mkdirp(RUNTIME) then return { ok = false, kind = kind, error = "cannot create GeoData runtime directory" } end
    local state = read_state(kind)
    if operation_active(state) then
        return { ok = false, kind = kind, error = "a GeoData update is already in progress" }
    end
    local result = probe(kind)
    if result.ok == true then
        if asset_ready(kind) then
            result.local_version = result.local_version or state.local_version or state.source_version
            if result.remote_version and result.local_version then
                result.update_available = result.remote_version ~= result.local_version
            end
        else
            result.local_version = nil
            result.update_available = nil
        end
    end
    state.status = "idle"
    state.progress = nil
    state.error = nil
    state.last_update = last_update_from_state(state)
    apply_check(state, result)
    save_state(kind, state)
    result.checked = state.checked
    result.check_ok = state.check_ok
    result.last_check_error = state.last_check_error
    result.last_update = state.last_update
    return result
end

local EXIT_HINTS = {
    [2] = "failed to write downloaded data",
    [3] = "failed to open the output file",
    [4] = "network connection failed",
    [5] = "TLS/SSL verification or handshake failed",
    [8] = "HTTP server returned an error"
}

local function last_error_line(output)
    local last
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        line = trim(line)
        if line ~= "" then last = line end
    end
    return last
end

local function download(asset, temporary, kind)
    if not asset.url:match("^https://") then return false, "GeoData source URL must use HTTPS" end
    if not exec_quiet("[ -x " .. shellquote(UCLIENT_FETCH) .. " ]") then return false, "uclient-fetch is unavailable" end

    local result_file = temporary_path(RUNTIME .. "/geo-fetch-result")
    local error_file = temporary_path(RUNTIME .. "/geo-fetch-error")
    os.remove(result_file)
    os.remove(error_file)

    local command = string.format(
        "(%s -T 15 -O %s %s >/dev/null 2>%s; printf '%%s' $? >%s) </dev/null & echo $!",
        shellquote(UCLIENT_FETCH), shellquote(temporary), shellquote(asset.url),
        shellquote(error_file), shellquote(result_file)
    )
    local pipe = io.popen(command, "r")
    local pid = pipe and tonumber(trim(pipe:read("*l") or "")) or nil
    if pipe then pipe:close() end
    if not pid then
        os.remove(result_file)
        os.remove(error_file)
        return false, "unable to start uclient-fetch"
    end

    while true do
        local raw = read_file(result_file)
        if raw and trim(raw) ~= "" then
            local code = tonumber(trim(raw)) or 1
            local detail = last_error_line(read_file(error_file))
            os.remove(result_file)
            os.remove(error_file)
            if code == 0 then return true end
            local hint = EXIT_HINTS[code] or "download failed"
            if detail and detail ~= "" then
                return false, string.format("uclient-fetch: %s (exit %d; %s)", detail, code, hint)
            end
            return false, string.format("uclient-fetch exit %d: %s", code, hint)
        end

        local stat = nixio_fs and nixio_fs.stat and nixio_fs.stat(temporary) or nil
        local state = read_state(kind)
        if state.status == "running" or state.status == "starting" then
            state.ok = true
            state.status = "running"
            state.pid = nixio.getpid()
            state.progress = { downloaded = stat and tonumber(stat.size) or 0 }
            save_state(kind, state)
        end
        exec_quiet("sleep 1")
    end
end

local function worker(kind)
    local asset = config(kind)
    if not asset then return { ok = false, kind = kind, status = "failed", error = "unsupported GeoData kind" } end

    local current = read_state(kind)
    local state = {
        ok = true,
        kind = kind,
        status = "running",
        started = tonumber(current.started) or os.time(),
        pid = nixio.getpid(),
        local_version = current.local_version or current.source_version,
        source_version = current.source_version,
        latest_version = current.latest_version,
        update_available = current.update_available,
        checked = current.checked,
        check_ok = current.check_ok,
        last_check_error = current.last_check_error,
        last_update = last_update_from_state(current),
        progress = { downloaded = 0 }
    }
    save_state(kind, state)

    if not mkdirp(dirname(asset.path)) then
        state.ok = false
        state.status = "failed"
        state.finished = os.time()
        state.error = "cannot create " .. dirname(asset.path)
        save_state(kind, state)
        remove_lock(kind)
        return state
    end

    local head_ok, head_output = exec_capture(UCLIENT_FETCH .. " -s -T 5 " .. shellquote(asset.url))
    local source_version = head_ok and release_version(head_output) or nil
    local temporary = temporary_path(asset.path .. ".nftflow-download")
    os.remove(temporary)
    local ok, err = download(asset, temporary, kind)
    if ok then
        local stat = nixio_fs and nixio_fs.stat and nixio_fs.stat(temporary) or nil
        if not stat or (tonumber(stat.size) or 0) < 1024 then
            ok = false
            err = "downloaded GeoData file is empty or implausibly small"
        end
    end
    if ok and not os.rename(temporary, asset.path) then
        ok = false
        err = "cannot atomically replace " .. asset.path
    end
    if ok then exec_quiet("chmod 0644 " .. shellquote(asset.path)) end
    if not ok then os.remove(temporary) end

    state.ok = ok == true
    state.finished = os.time()
    state.updated = ok == true
    state.progress = nil
    state.message = ok and (kind .. " updated") or nil
    state.error = ok and nil or (err or "GeoData download failed")
    if ok then
        state.source_version = source_version or state.source_version
        state.local_version = source_version or state.local_version
        state.persist_error = nil
        if source_version then
            local persisted, persist_error = geodata_version.write(kind, source_version)
            if not persisted then state.persist_error = persist_error or "cannot persist installed GeoData version" end
        end
        state.last_update = state.finished
        state.checked = state.finished
        state.check_ok = true
        state.last_check_error = nil
        state.post_check_error = nil
        if source_version then
            state.latest_version = source_version
            state.update_available = false
        else
            state.update_available = nil
        end
    end
    state.status = ok and "done" or "failed"
    save_state(kind, state)
    remove_lock(kind)
    return state
end

local function start(kind)
    if not config(kind) then return { ok = false, kind = kind, error = "unsupported GeoData kind" } end
    if not mkdirp(RUNTIME) or not mkdirp(LOG_DIR) then
        return { ok = false, kind = kind, error = "cannot create GeoData runtime directory" }
    end

    local current = read_state(kind)
    if operation_active(current) then
        current.ok = true
        return current
    end
    remove_lock(kind)
    if not exec_quiet("mkdir " .. shellquote(lock_path(kind))) then
        return { ok = false, kind = kind, status = "busy", error = "another GeoData update is starting" }
    end

    local state = {
        ok = true,
        kind = kind,
        status = "starting",
        started = os.time(),
        local_version = current.local_version or current.source_version,
        source_version = current.source_version,
        latest_version = current.latest_version,
        update_available = current.update_available,
        checked = current.checked,
        check_ok = current.check_ok,
        last_check_error = current.last_check_error,
        last_update = last_update_from_state(current),
        progress = { downloaded = 0 },
        message = "GeoData download started"
    }
    local saved, save_error = save_state(kind, state)
    if not saved then
        remove_lock(kind)
        return { ok = false, kind = kind, status = "failed", error = save_error or "cannot save GeoData update state" }
    end

    local log_path = LOG_DIR .. "/geo-update-" .. kind .. ".log"
    local launch = string.format(
        "/usr/bin/lua /usr/libexec/nftflow/geo-update.lua worker %s </dev/null >>%s 2>&1 & echo $!",
        shellquote(kind), shellquote(log_path)
    )
    local pipe = io.popen(launch, "r")
    local pid = pipe and tonumber(trim(pipe:read("*l") or "")) or nil
    if pipe then pipe:close() end
    if not pid then
        remove_lock(kind)
        state.ok = false
        state.status = "failed"
        state.finished = os.time()
        state.error = "unable to start GeoData update worker"
        save_state(kind, state)
        return state
    end
    state.pid = pid
    save_state(kind, state)
    return state
end

local function auto_update()
    local results = {}
    local ok = true
    for _, kind in ipairs({ "geoip", "geosite" }) do
        local result = start(kind)
        results[kind] = result
        if result.ok ~= true then ok = false end
    end
    return {
        ok = ok,
        status = ok and "starting" or "failed",
        automatic = true,
        updates = results,
        message = ok and "Weekly GeoData update started" or "Weekly GeoData update could not start"
    }
end

local function status()
    local assets = {}
    for _, kind in ipairs({ "geoip", "geosite" }) do
        local state = read_state(kind)
        assets[kind] = {
            kind = kind,
            local_version = state.local_version or state.source_version,
            checked = tonumber(state.checked),
            check_ok = state.check_ok,
            latest_version = state.latest_version,
            update_available = state.update_available,
            last_check_error = state.last_check_error,
            last_update = last_update_from_state(state),
            post_check_error = state.post_check_error
        }
    end
    return { ok = true, assets = assets }
end

local function next_weekly_run(now)
    now = tonumber(now) or os.time()
    local current = os.date("*t", now)
    local days_until_sunday = (1 - current.wday) % 7
    local candidate = os.time({
        year = current.year,
        month = current.month,
        day = current.day + days_until_sunday,
        hour = 4,
        min = 17,
        sec = 0
    })
    if candidate <= now then candidate = candidate + 7 * 24 * 60 * 60 end
    return candidate
end

local command = arg[1] or ""
local result
if command == "start" then
    result = start(arg[2])
elseif command == "worker" then
    result = worker(arg[2])
elseif command == "auto-update" then
    result = auto_update()
elseif command == "check" then
    result = check(arg[2])
elseif command == "status" then
    result = status()
elseif command == "next-run" then
    result = { ok = true, next_update = next_weekly_run() }
else
    result = { ok = false, error = "unknown GeoData updater command" }
end
io.write(encode(result) .. "\n")
os.exit(result.ok == false and 1 or 0)