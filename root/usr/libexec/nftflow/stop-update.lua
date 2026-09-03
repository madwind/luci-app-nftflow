#!/usr/bin/lua
-- SPDX-License-Identifier: Apache-2.0
-- Stop active NftFlow/GeoData update workers without interrupting package installation.

local jsonc = require "luci.jsonc"
local nixio = require "nixio"

local RUNTIME = "/var/run/nftflow"
local SOFTWARE_DIR = "/tmp/nftflow-update"

local function encode(value)
    if jsonc.stringify then return jsonc.stringify(value) end
    return jsonc.encode(value)
end

local function decode(value)
    local decoder = jsonc.parse or jsonc.decode
    local ok, result = pcall(decoder, value)
    return ok and result or nil
end

local function shellquote(value)
    return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function exec_quiet(command)
    local ok = os.execute(command .. " >/dev/null 2>&1")
    return ok == true or ok == 0
end

local function read_file(path, mode)
    local file = io.open(path, mode or "r")
    if not file then return nil end
    local value = file:read("*a")
    file:close()
    return value
end

local function write_atomic(path, value)
    local temporary = string.format("%s.stop.%d", path, nixio.getpid())
    local file, err = io.open(temporary, "w")
    if not file then return false, err or "cannot open update state temporary file" end
    if not file:write(value) then
        file:close()
        os.remove(temporary)
        return false, "cannot write update state"
    end
    local closed, close_error = file:close()
    if not closed then
        os.remove(temporary)
        return false, close_error or "cannot close update state"
    end
    exec_quiet("chmod 0600 " .. shellquote(temporary))
    if not os.rename(temporary, path) then
        os.remove(temporary)
        return false, "cannot replace update state"
    end
    return true
end

local function paths(kind)
    if kind == "geoip" or kind == "geosite" then
        return {
            mode = "geo",
            state = RUNTIME .. "/geo-update-" .. kind .. ".json",
            lock = RUNTIME .. "/geo-update-" .. kind .. ".lock",
            worker = "/usr/libexec/nftflow/geo-update.lua"
        }
    elseif kind == "nftflow" or kind == "xray" then
        return {
            mode = "software",
            state = SOFTWARE_DIR .. "/" .. kind .. ".json",
            lock = SOFTWARE_DIR .. "/" .. kind .. ".lock",
            worker = "/usr/libexec/nftflow/update.lua"
        }
    end
    return nil
end

local function read_state(path, kind)
    local raw = read_file(path)
    local value = raw and decode(raw) or nil
    if type(value) ~= "table" then return { kind = kind, status = "idle" } end
    value.kind = kind
    return value
end

local function process_alive(pid)
    pid = tonumber(pid)
    return pid and pid > 1 and exec_quiet("kill -0 " .. tostring(math.floor(pid)))
end

local function worker_matches(pid, worker, kind)
    local raw = read_file(string.format("/proc/%d/cmdline", pid), "rb")
    if not raw then return false end
    local command = raw:gsub("%z", " ")
    return command:find(worker, 1, true) ~= nil and
        command:find("worker", 1, true) ~= nil and
        command:find(kind, 1, true) ~= nil
end

local function collect_children(pid, result, seen)
    if seen[pid] then return end
    seen[pid] = true
    local raw = read_file(string.format("/proc/%d/task/%d/children", pid, pid)) or ""
    for child in raw:gmatch("%d+") do
        child = tonumber(child)
        if child and child > 1 and not seen[child] then
            collect_children(child, result, seen)
            result[#result + 1] = child
        end
    end
end

local function any_alive(pid, children)
    if process_alive(pid) then return true end
    for _, child in ipairs(children) do
        if process_alive(child) then return true end
    end
    return false
end

local function terminate_tree(pid)
    local children = {}
    collect_children(pid, children, {})

    for _, child in ipairs(children) do
        exec_quiet("kill -TERM " .. tostring(child))
    end
    exec_quiet("kill -TERM " .. tostring(pid))

    for _ = 1, 3 do
        if not any_alive(pid, children) then return true end
        exec_quiet("sleep 1")
    end

    for _, child in ipairs(children) do
        if process_alive(child) then exec_quiet("kill -KILL " .. tostring(child)) end
    end
    if process_alive(pid) then exec_quiet("kill -KILL " .. tostring(pid)) end
    return not any_alive(pid, children)
end

local function stop(kind)
    local info = paths(kind)
    if not info then return { ok = false, kind = kind, error = "unsupported update kind" } end

    local state = read_state(info.state, kind)
    local active = state.status == "starting" or state.status == "running" or state.status == "stopping"
    local pid = tonumber(state.pid)
    if not active or not pid or pid <= 1 or not process_alive(pid) then
        return { ok = false, kind = kind, status = state.status, error = "no active update to stop" }
    end

    if info.mode == "software" then
        if kind == "xray" then
            return { ok = false, kind = kind, status = state.status, error = "Xray Core package update cannot be stopped safely" }
        end
        if state.phase == "installing" then
            return { ok = false, kind = kind, status = state.status, error = "NftFlow package installation cannot be stopped safely" }
        end
    end

    if not worker_matches(pid, info.worker, kind) then
        return { ok = false, kind = kind, status = state.status, error = "refusing to stop an unexpected process" }
    end

    state.status = "stopping"
    state.message = "Stopping update"
    state.error = nil
    write_atomic(info.state, encode(state) .. "\n")

    if not terminate_tree(pid) then
        state.ok = false
        state.status = "failed"
        state.finished = os.time()
        state.error = "unable to stop update worker"
        write_atomic(info.state, encode(state) .. "\n")
        return state
    end

    exec_quiet("rmdir " .. shellquote(info.lock))

    state.ok = true
    state.status = "stopped"
    if info.mode == "software" then state.phase = "stopped" end
    state.finished = os.time()
    state.pid = nil
    state.progress = nil
    state.updated = false
    state.error = nil
    state.message = "Update stopped"
    local saved, save_error = write_atomic(info.state, encode(state) .. "\n")
    if not saved then
        return { ok = false, kind = kind, status = "stopped", error = save_error or "cannot save stopped update state" }
    end
    return state
end

local kind = arg[1] or ""
local result = stop(kind)
io.write(encode(result) .. "\n")
os.exit(result.ok == false and 1 or 0)
