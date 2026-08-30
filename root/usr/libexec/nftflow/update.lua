#!/usr/bin/lua
-- SPDX-License-Identifier: Apache-2.0
-- Software updater for NftFlow and the packaged Xray Core.

local jsonc = require "luci.jsonc"
local nixio = require "nixio"
local nixio_fs = require "nixio.fs"

local UPDATE_DIR = "/tmp/nftflow-update"
local MANIFEST_URL = "https://github.com/madwind/luci-app-nftflow/releases/latest/download/nftflow-update.json"
local RELEASE_BASE = "https://github.com/madwind/luci-app-nftflow/releases/download/"
local UCLIENT_FETCH = "/bin/uclient-fetch"
local sequence = 0

local PACKAGES = {
    nftflow = "luci-app-nftflow",
    xray = "xray-core"
}

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
    if not pipe then return false, "unable to execute command", 1 end
    local output = pipe:read("*a") or ""
    local ok, reason, code = pipe:close()
    if ok == true or code == 0 then return true, output, 0 end
    return false, trim(output ~= "" and output or (reason or "command failed")), tonumber(code) or 1
end

local function exec_quiet(command)
    local ok = os.execute(command .. " >/dev/null 2>&1")
    return ok == true or ok == 0
end

local function mkdirp(path)
    if nixio_fs and nixio_fs.mkdirr then return nixio_fs.mkdirr(path) end
    return exec_quiet("mkdir -p " .. shellquote(path))
end

local function read_file(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local value = file:read("*a")
    file:close()
    return value
end

local function temporary_path(base)
    sequence = sequence + 1
    local seconds, microseconds = nixio.gettimeofday()
    return string.format("%s.tmp.%d.%d.%d.%d", base, nixio.getpid(), seconds, microseconds or 0, sequence)
end

local function write_atomic(path, value)
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
    exec_quiet("chmod 0600 " .. shellquote(temporary))
    if not os.rename(temporary, path) then
        os.remove(temporary)
        return false, "cannot replace " .. path
    end
    return true
end

local function state_path(kind)
    return UPDATE_DIR .. "/" .. kind .. ".json"
end

local function lock_path(kind)
    return UPDATE_DIR .. "/" .. kind .. ".lock"
end

local function read_state(kind)
    local raw = read_file(state_path(kind))
    local value = raw and decode(raw) or nil
    if type(value) ~= "table" then return { kind = kind, status = "idle" } end
    value.kind = kind
    return value
end

local function save_state(kind, state)
    state.kind = kind
    mkdirp(UPDATE_DIR)
    return write_atomic(state_path(kind), encode(state) .. "\n")
end

local function remove_lock(kind)
    exec_quiet("rmdir " .. shellquote(lock_path(kind)))
end

local function process_alive(pid)
    pid = tonumber(pid)
    return pid and pid > 1 and exec_quiet("kill -0 " .. tostring(math.floor(pid)))
end

local function compact_error(output)
    local lines = {}
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        line = trim(line)
        if line ~= "" then
            lines[#lines + 1] = line
            if #lines > 6 then table.remove(lines, 1) end
        end
    end
    return table.concat(lines, " | ")
end

local function parse_package_version(package_name, output)
    local prefix = package_name .. "-"
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        local token = line:match("^(%S+)")
        if token and token:sub(1, #prefix) == prefix then
            return token:sub(#prefix + 1)
        end
    end
    return nil
end

local function installed_version(package_name)
    local ok, output = exec_capture("apk list -I " .. shellquote(package_name))
    if not ok then return nil end
    return parse_package_version(package_name, output)
end

local function version_relation(left, right)
    if not left or not right then return nil end
    local ok, output = exec_capture("apk version -t " .. shellquote(left) .. " " .. shellquote(right))
    if not ok then return nil end
    return trim(output):match("[<=>]")
end

local function is_update_available(installed, latest)
    local relation = version_relation(latest, installed)
    if not relation then return nil end
    return relation == ">"
end

local function newest_version(package_name, output)
    local prefix = package_name .. "-"
    local newest = nil
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        local token = line:match("^(%S+)")
        if token and token:sub(1, #prefix) == prefix then
            local candidate = token:sub(#prefix + 1)
            if not newest or version_relation(candidate, newest) == ">" then newest = candidate end
        end
    end
    return newest
end

local function fetch_file(url, path)
    if not tostring(url or ""):match("^https://") then return false, "download URL must use HTTPS" end
    if not exec_quiet("[ -x " .. shellquote(UCLIENT_FETCH) .. " ]") then return false, "uclient-fetch is unavailable" end
    os.remove(path)
    local ok, output, code = exec_capture(shellquote(UCLIENT_FETCH) .. " -T 15 -O " .. shellquote(path) .. " " .. shellquote(url))
    if ok then return true end
    os.remove(path)
    local detail = compact_error(output)
    if detail == "" then detail = "uclient-fetch exited with status " .. tostring(code) end
    return false, detail
end

local function validate_manifest(manifest)
    if type(manifest) ~= "table" then return false, "update manifest is not valid JSON" end
    local version = trim(manifest.version)
    local tag = trim(manifest.tag)
    local asset = trim(manifest.asset)
    local sha256 = trim(manifest.sha256):lower()
    if version == "" or not version:match("^[%w%._+%-]+$") then return false, "update manifest has an invalid version" end
    if tag == "" or not tag:match("^[%w%._+%-]+$") then return false, "update manifest has an invalid tag" end
    if asset == "" or asset:find("/", 1, true) or not asset:match("^luci%-app%-nftflow%-.+%.apk$") then
        return false, "update manifest has an invalid package asset"
    end
    if not sha256:match("^[0-9a-f]+$") or #sha256 ~= 64 then return false, "update manifest has an invalid SHA256" end
    return true, {
        version = version,
        tag = tag,
        asset = asset,
        sha256 = sha256,
        url = RELEASE_BASE .. tag .. "/" .. asset
    }
end

local function probe_nftflow()
    if not mkdirp(UPDATE_DIR) then return { ok = false, kind = "nftflow", error = "cannot create update directory" } end
    local manifest_path = temporary_path(UPDATE_DIR .. "/manifest")
    local ok, err = fetch_file(MANIFEST_URL, manifest_path)
    if not ok then
        if tostring(err):match("404") then
            return {
                ok = true,
                kind = "nftflow",
                installed_version = installed_version(PACKAGES.nftflow),
                latest_version = nil,
                update_available = false,
                no_release = true,
                message = "No published NftFlow release"
            }
        end
        return { ok = false, kind = "nftflow", error = "NftFlow release check failed: " .. tostring(err) }
    end
    local raw = read_file(manifest_path) or ""
    os.remove(manifest_path)
    local valid, manifest_or_error = validate_manifest(decode(raw))
    if not valid then return { ok = false, kind = "nftflow", error = manifest_or_error } end
    local manifest = manifest_or_error
    local installed = installed_version(PACKAGES.nftflow)
    return {
        ok = true,
        kind = "nftflow",
        installed_version = installed,
        latest_version = manifest.version,
        update_available = is_update_available(installed, manifest.version),
        manifest = manifest
    }
end

local function probe_xray()
    local installed = installed_version(PACKAGES.xray)
    if not installed then return { ok = false, kind = "xray", error = "xray-core is not installed" } end
    local ok, output = exec_capture("apk update")
    if not ok then return { ok = false, kind = "xray", error = "apk update failed: " .. compact_error(output) } end
    ok, output = exec_capture("apk list -a " .. shellquote(PACKAGES.xray))
    if not ok then return { ok = false, kind = "xray", error = "unable to list xray-core versions: " .. compact_error(output) } end
    local latest = newest_version(PACKAGES.xray, output)
    if not latest then return { ok = false, kind = "xray", error = "xray-core is unavailable from configured APK repositories" } end
    return {
        ok = true,
        kind = "xray",
        installed_version = installed,
        latest_version = latest,
        update_available = is_update_available(installed, latest)
    }
end

local function last_update_from_state(state)
    local value = tonumber(state and state.last_update)
    if value then return value end
    if state and state.updated == true then return tonumber(state.finished) end
    return nil
end

local function apply_probe(state, result)
    state.checked = os.time()
    state.check_ok = result.ok == true
    if result.ok == true then
        state.installed_version = result.installed_version or state.installed_version
        state.latest_version = result.latest_version
        state.update_available = result.update_available
        state.no_release = result.no_release == true
        state.last_check_error = nil
    else
        state.installed_version = installed_version(PACKAGES[state.kind]) or state.installed_version
        if state.latest_version then
            state.update_available = is_update_available(state.installed_version, state.latest_version)
        end
        state.last_check_error = result.error or "update check failed"
    end
    return result
end

local function save_check(result)
    local current = read_state(result.kind)
    local state = {
        ok = true,
        kind = result.kind,
        status = "idle",
        installed_version = current.installed_version,
        latest_version = current.latest_version,
        update_available = current.update_available,
        no_release = current.no_release == true,
        last_update = last_update_from_state(current)
    }
    apply_probe(state, result)
    save_state(result.kind, state)
    result.checked = state.checked
    result.check_ok = state.check_ok
    result.last_check_error = state.last_check_error
    result.last_update = state.last_update
    return result
end

local function check(kind)
    local current = read_state(kind)
    if (current.status == "starting" or current.status == "running") and process_alive(current.pid) then
        current.ok = false
        current.error = "an update is already in progress"
        return current
    end
    if kind == "nftflow" then return save_check(probe_nftflow()) end
    if kind == "xray" then return save_check(probe_xray()) end
    return { ok = false, kind = kind, error = "unsupported update kind" }
end

local function fail_worker(kind, state, message)
    state.ok = false
    state.status = "failed"
    state.phase = "failed"
    state.finished = os.time()
    state.error = message or "update failed"
    save_state(kind, state)
    remove_lock(kind)
    return state
end

local function done_worker(kind, state, updated, message)
    state.ok = true
    state.status = "done"
    state.phase = "done"
    state.finished = os.time()
    state.updated = updated == true
    state.message = message
    state.error = nil
    state.installed_version = installed_version(PACKAGES[kind]) or state.installed_version
    if state.latest_version then state.update_available = is_update_available(state.installed_version, state.latest_version) end
    if state.updated then state.last_update = state.finished end
    save_state(kind, state)
    remove_lock(kind)
    return state
end

local function set_phase(kind, state, phase, message)
    state.ok = true
    state.status = "running"
    state.phase = phase
    state.message = message
    state.pid = nixio.getpid()
    save_state(kind, state)
end

local function post_check(kind, state)
    set_phase(kind, state, "checking", kind == "nftflow" and "Checking installed NftFlow version" or "Checking installed xray-core version")
    local result = kind == "nftflow" and probe_nftflow() or probe_xray()
    apply_probe(state, result)
    if result.ok == true then
        state.post_check_error = nil
    else
        state.post_check_error = result.error or "verification check failed"
    end
    return result
end

local function worker_nftflow(state)
    set_phase("nftflow", state, "checking", "Checking NftFlow release")
    local probe = probe_nftflow()
    apply_probe(state, probe)
    if probe.ok ~= true then return fail_worker("nftflow", state, probe.error) end
    if probe.no_release then return done_worker("nftflow", state, false, "No published NftFlow release") end
    if probe.update_available ~= true then return done_worker("nftflow", state, false, "NftFlow is already up to date") end

    local manifest = probe.manifest
    local package_path = temporary_path(UPDATE_DIR .. "/" .. manifest.asset)
    set_phase("nftflow", state, "downloading", "Downloading NftFlow package")
    local ok, err = fetch_file(manifest.url, package_path)
    if not ok then return fail_worker("nftflow", state, "NftFlow download failed: " .. tostring(err)) end

    set_phase("nftflow", state, "verifying", "Verifying NftFlow package")
    local hash_ok, hash_output = exec_capture("sha256sum " .. shellquote(package_path))
    local actual = hash_ok and tostring(hash_output):match("^([0-9A-Fa-f]+)") or nil
    if not actual then
        os.remove(package_path)
        return fail_worker("nftflow", state, "SHA256 verification failed: " .. compact_error(hash_output))
    end
    if actual:lower() ~= manifest.sha256 then
        os.remove(package_path)
        return fail_worker("nftflow", state, "SHA256 mismatch: expected " .. manifest.sha256 .. ", got " .. actual:lower())
    end

    set_phase("nftflow", state, "installing", "Installing NftFlow package")
    local install_ok, install_output = exec_capture("apk add --allow-untrusted --upgrade " .. shellquote(package_path))
    os.remove(package_path)
    if not install_ok then return fail_worker("nftflow", state, "NftFlow installation failed: " .. compact_error(install_output)) end
    post_check("nftflow", state)
    return done_worker("nftflow", state, true, "NftFlow updated successfully")
end

local function worker_xray(state)
    set_phase("xray", state, "checking", "Checking xray-core package")
    local probe = probe_xray()
    apply_probe(state, probe)
    if probe.ok ~= true then return fail_worker("xray", state, probe.error) end
    if probe.update_available ~= true then return done_worker("xray", state, false, "Xray Core is already up to date") end

    local was_running = exec_quiet("/etc/init.d/nftflow running")
    if was_running then exec_quiet("/etc/init.d/nftflow stop") end
    set_phase("xray", state, "installing", "Installing xray-core package")
    local ok, output = exec_capture("apk -U upgrade " .. shellquote(PACKAGES.xray))
    if was_running then exec_quiet("/etc/init.d/nftflow start") end
    if not ok then return fail_worker("xray", state, "xray-core installation failed: " .. compact_error(output)) end
    post_check("xray", state)
    return done_worker("xray", state, true, "Xray Core updated successfully")
end

local function worker(kind)
    if not PACKAGES[kind] then return { ok = false, kind = kind, error = "unsupported update kind" } end
    local current = read_state(kind)
    local state = {
        ok = true,
        kind = kind,
        status = "running",
        phase = "starting",
        started = tonumber(current.started) or os.time(),
        pid = nixio.getpid(),
        installed_version = current.installed_version,
        latest_version = current.latest_version,
        update_available = current.update_available,
        no_release = current.no_release == true,
        checked = current.checked,
        check_ok = current.check_ok,
        last_check_error = current.last_check_error,
        last_update = last_update_from_state(current)
    }
    save_state(kind, state)
    if kind == "nftflow" then return worker_nftflow(state) end
    return worker_xray(state)
end

local function start(kind)
    if not PACKAGES[kind] then return { ok = false, kind = kind, error = "unsupported update kind" } end
    if not mkdirp(UPDATE_DIR) then return { ok = false, kind = kind, error = "cannot create update directory" } end
    local current = read_state(kind)
    if (current.status == "starting" or current.status == "running") and process_alive(current.pid) then
        current.ok = true
        return current
    end
    remove_lock(kind)
    if not exec_quiet("mkdir " .. shellquote(lock_path(kind))) then
        return { ok = false, kind = kind, status = "busy", error = "another update is starting" }
    end
    local state = {
        ok = true,
        kind = kind,
        status = "starting",
        phase = "starting",
        started = os.time(),
        installed_version = installed_version(PACKAGES[kind]),
        latest_version = current.latest_version,
        update_available = current.update_available,
        no_release = current.no_release == true,
        checked = current.checked,
        check_ok = current.check_ok,
        last_check_error = current.last_check_error,
        last_update = last_update_from_state(current),
        message = "Update started"
    }
    local saved, save_error = save_state(kind, state)
    if not saved then
        remove_lock(kind)
        return { ok = false, kind = kind, status = "failed", error = save_error or "cannot save update state" }
    end
    local log_path = UPDATE_DIR .. "/" .. kind .. ".log"
    local launch = string.format(
        "/usr/bin/lua /usr/libexec/nftflow/update.lua worker %s </dev/null >>%s 2>&1 & echo $!",
        shellquote(kind), shellquote(log_path)
    )
    local pipe = io.popen(launch, "r")
    local pid = pipe and tonumber(trim(pipe:read("*l") or "")) or nil
    if pipe then pipe:close() end
    if not pid then
        remove_lock(kind)
        state.ok = false
        state.status = "failed"
        state.phase = "failed"
        state.error = "unable to start update worker"
        save_state(kind, state)
        return state
    end
    state.pid = pid
    save_state(kind, state)
    return state
end

local function component_status(kind)
    local state = read_state(kind)
    local installed = installed_version(PACKAGES[kind])
    local latest = state.latest_version
    local available = latest and is_update_available(installed, latest) or nil
    return {
        kind = kind,
        installed_version = installed,
        latest_version = latest,
        update_available = available,
        no_release = state.no_release == true,
        checked = state.checked,
        check_ok = state.check_ok,
        last_check_error = state.last_check_error,
        last_update = last_update_from_state(state),
        operation = state
    }
end

local function status()
    return {
        ok = true,
        components = {
            nftflow = component_status("nftflow"),
            xray = component_status("xray")
        }
    }
end

local command = arg[1] or ""
local result
if command == "status" then
    result = status()
elseif command == "check" then
    result = check(arg[2])
elseif command == "start" then
    result = start(arg[2])
elseif command == "worker" then
    result = worker(arg[2])
else
    result = { ok = false, error = "unknown update command" }
end

io.write(encode(result) .. "\n")
os.exit(result.ok == false and 1 or 0)
