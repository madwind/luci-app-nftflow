#!/usr/bin/lua

local jsonc = require "luci.jsonc"

local GEO_UPDATE = "/usr/libexec/nftflow/geo-update.lua"

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
    return ok == true or code == 0, output ~= "" and output or tostring(reason or "command failed")
end

local function last_json(output)
    local value
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        line = trim(line)
        if line ~= "" then
            local parsed = decode(line)
            if type(parsed) == "table" then value = parsed end
        end
    end
    return value
end

local function run_geo(command, kind)
    local line = "/usr/bin/lua " .. shellquote(GEO_UPDATE) .. " " .. shellquote(command)
    if kind then line = line .. " " .. shellquote(kind) end
    local ok, output = exec_capture(line)
    local result = last_json(output)
    if result then return result end
    return { ok = false, kind = kind, error = ok and "GeoData updater returned invalid JSON" or trim(output) }
end

local function flag(kind)
    local ok, output = exec_capture("/sbin/uci -q get nftflow.main." .. kind .. "_auto_update")
    return ok and trim(output) == "1"
end

local function smart_update(kind)
    if kind ~= "geoip" and kind ~= "geosite" then
        return { ok = false, kind = kind, error = "unsupported GeoData kind" }
    end
    local checked = run_geo("check", kind)
    if checked.ok ~= true then return checked end
    if checked.local_version and checked.local_version ~= "" and checked.update_available == false then
        checked.message = kind .. " is already up to date"
        return checked
    end
    return run_geo("start", kind)
end

local function auto_update()
    local results = {}
    local ok = true
    local enabled = 0
    for _, kind in ipairs({ "geoip", "geosite" }) do
        if flag(kind) then
            enabled = enabled + 1
            results[kind] = smart_update(kind)
            if results[kind].ok ~= true then ok = false end
        else
            results[kind] = { ok = true, kind = kind, status = "disabled" }
        end
    end
    return {
        ok = ok,
        automatic = true,
        enabled = enabled,
        updates = results,
        message = enabled > 0 and "Automatic GeoData update checked" or "Automatic GeoData update is disabled"
    }
end

local command = arg[1] or ""
local result
if command == "update" then result = smart_update(arg[2])
elseif command == "auto" then result = auto_update()
else result = { ok = false, error = "unknown smart GeoData update command" } end

io.write(encode(result) .. "\n")
os.exit(result.ok == false and 1 or 0)
