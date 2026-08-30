#!/usr/bin/lua
-- SPDX-License-Identifier: Apache-2.0
-- Xray JSON frontend with validation, temporary runtime apply and persistent save.

local jsonc = require "luci.jsonc"
local nixio = require "nixio"
local nixio_fs = require "nixio.fs"

local RUNTIME = "/var/run/nftflow"
local APPLIED_CONFIG = RUNTIME .. "/config.applied.json"
local EDITOR_MAX_BYTES = 32 * 1024
local temporary_sequence = 0

local function json_encode(value)
    if jsonc.stringify then return jsonc.stringify(value) end
    return jsonc.encode(value)
end

local function json_decode(value)
    if jsonc.parse then return jsonc.parse(value) end
    return jsonc.decode(value)
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

local function mkdirp(path)
    if nixio_fs and nixio_fs.mkdirr then return nixio_fs.mkdirr(path) end
    return exec_quiet("mkdir -p " .. shellquote(path))
end

local function dirname(path)
    return tostring(path):match("^(.*)/[^/]*$") or "."
end

local function read_file(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local value = file:read("*a")
    file:close()
    return value
end

local function temporary_path(path)
    temporary_sequence = temporary_sequence + 1
    local seconds, microseconds = nixio.gettimeofday()
    return string.format("%s.tmp.%d.%d.%d.%d", path, nixio.getpid(), seconds, microseconds or 0, temporary_sequence)
end

local function write_atomic(path, value, mode)
    if not mkdirp(dirname(path)) then return false, "cannot create " .. dirname(path) end
    local temporary = temporary_path(path)
    local file, open_error = io.open(temporary, "w")
    if not file then return false, open_error or "cannot open temporary file" end
    local written, write_error = file:write(value)
    if not written then
        file:close()
        os.remove(temporary)
        return false, write_error or "cannot write temporary file"
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
    if mode then exec_quiet("chmod " .. tostring(mode) .. " " .. shellquote(path)) end
    return true
end

local function restore_file(path, value)
    if value == nil then
        os.remove(path)
        return true
    end
    return write_atomic(path, value, 600) == true
end

local function uci_get(option, default)
    local ok, output = exec_capture("/sbin/uci -q get nftflow.main." .. option)
    output = trim(output)
    return ok and output ~= "" and output or default
end

local function main_config()
    return {
        xray_bin = uci_get("xray_bin", "/usr/bin/xray"),
        config_file = uci_get("config_file", "/etc/nftflow/config.json"),
        asset_dir = uci_get("asset_dir", "/usr/share/xray")
    }
end

local function normalize(raw)
    raw = tostring(raw or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if raw ~= "" and raw:sub(-1) ~= "\n" then raw = raw .. "\n" end
    return raw
end

local function parse_document(raw, path)
    if raw == nil then return nil, "cannot read " .. tostring(path) end
    if #raw > EDITOR_MAX_BYTES then return nil, "configuration is larger than 32 KiB" end
    if raw:find("%z") then return nil, "configuration contains a NUL byte" end
    local ok, value = pcall(json_decode, raw)
    if not ok or type(value) ~= "table" then return nil, "invalid JSON in " .. tostring(path) end
    local has_number = false
    for key in pairs(value) do
        if type(key) ~= "string" then has_number = true; break end
    end
    if has_number or trim(raw):sub(1, 1) ~= "{" then
        return nil, "JSON document root must be an object"
    end
    return value
end

local function validate(raw)
    local main = main_config()
    local source = normalize(raw)
    local _, parse_error = parse_document(source, main.config_file)
    if parse_error then
        return { ok = false, valid = false, error = parse_error }
    end
    if not exec_quiet("[ -x " .. shellquote(main.xray_bin) .. " ]") then
        return { ok = false, valid = false, error = "Xray binary is unavailable: " .. main.xray_bin }
    end
    if not mkdirp(RUNTIME) then
        return { ok = false, valid = false, error = "cannot create " .. RUNTIME }
    end

    local check_path = temporary_path(RUNTIME .. "/config-check.json")
    local saved, save_error = write_atomic(check_path, source, 600)
    if not saved then return { ok = false, valid = false, error = save_error } end

    local command = "XRAY_LOCATION_ASSET=" .. shellquote(main.asset_dir) .. " " ..
        shellquote(main.xray_bin) .. " run -test -format json -config " .. shellquote(check_path)
    local valid, output = exec_capture(command)
    os.remove(check_path)

    local result = {
        ok = valid,
        valid = valid,
        config = source,
        bytes = #source,
        detail = trim(output)
    }
    if not valid then result.error = "Xray configuration test failed" end
    return result
end

local function read()
    local main = main_config()
    local source = read_file(main.config_file)
    if source == nil then
        return { ok = false, error = "cannot read " .. main.config_file, path = main.config_file }
    end
    local _, parse_error = parse_document(source, main.config_file)
    return {
        ok = true,
        config = source,
        path = main.config_file,
        bytes = #source,
        syntax = parse_error == nil,
        error = parse_error,
        applied = read_file(APPLIED_CONFIG) ~= nil,
        applied_path = APPLIED_CONFIG
    }
end

local function save(raw)
    local main = main_config()
    local source = normalize(raw)
    local _, parse_error = parse_document(source, main.config_file)
    if parse_error then return { ok = false, valid = false, error = parse_error } end
    local saved, save_error = write_atomic(main.config_file, source, 600)
    if not saved then return { ok = false, error = save_error } end
    return {
        ok = true,
        valid = true,
        config = source,
        path = main.config_file,
        bytes = #source
    }
end

local function apply(raw)
    local checked = validate(raw)
    if not checked.valid then return checked end

    local previous = read_file(APPLIED_CONFIG)
    local saved, save_error = write_atomic(APPLIED_CONFIG, checked.config, 600)
    if not saved then return { ok = false, valid = true, error = save_error } end

    local command = "NFTFLOW_FORCE_START=1 NFTFLOW_CONFIG_OVERRIDE=" .. shellquote(APPLIED_CONFIG) ..
        " /etc/init.d/nftflow restart"
    local restarted, output = exec_capture(command)
    if not restarted then
        restore_file(APPLIED_CONFIG, previous)
        return {
            ok = false,
            valid = true,
            error = "failed to restart NftFlow with the applied configuration",
            detail = trim(output)
        }
    end

    return {
        ok = true,
        valid = true,
        applied = true,
        config = checked.config,
        applied_config = checked.config,
        applied_path = APPLIED_CONFIG,
        detail = trim(output)
    }
end

local function read_rpc_input(path)
    path = tostring(path or "")
    if not path:match("^/var/run/nftflow/rpc%-[A-Za-z0-9]+/payload$") then
        return nil, "invalid internal RPC input path"
    end
    local raw = read_file(path)
    if raw == nil then return nil, "cannot read internal RPC input file" end
    return raw
end

local function dispatch(command, args)
    if command == "config-read" then return read() end
    if command == "config-validate" then return validate(args[1]) end
    if command == "config-save" then return save(args[1]) end
    if command == "config-apply" then return apply(args[1]) end
    if command == "config-validate-file" or command == "config-save-file" or command == "config-apply-file" then
        local raw, read_error = read_rpc_input(args[1])
        if raw == nil then return { ok = false, valid = false, error = read_error } end
        if command == "config-validate-file" then return validate(raw) end
        if command == "config-save-file" then return save(raw) end
        return apply(raw)
    end
    return { ok = false, error = "unsupported config command: " .. tostring(command) }
end

local command, args = arg[1] or "", {}
for index = 2, #arg do args[#args + 1] = arg[index] end
local ok, result = pcall(dispatch, command, args)
local code = 0
if not ok then result, code = { ok = false, error = tostring(result) }, 1
elseif type(result) ~= "table" then result = { ok = true, result = result }
elseif result.ok == false then code = 1 end
io.write(json_encode(result) .. "\n")
os.exit(code)
