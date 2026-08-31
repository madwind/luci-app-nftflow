-- SPDX-License-Identifier: Apache-2.0
-- Persist only the installed GeoData release versions across reboots.

local M = {}
local BASE = "/etc/nftflow"

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function valid_kind(kind)
    return kind == "geoip" or kind == "geosite"
end

local function path_for(kind)
    if not valid_kind(kind) then return nil end
    return BASE .. "/" .. kind .. ".version"
end

function M.read(kind)
    local path = path_for(kind)
    if not path then return nil end
    local file = io.open(path, "r")
    if not file then return nil end
    local value = trim(file:read("*a"))
    file:close()
    return value ~= "" and value or nil
end

function M.write(kind, version)
    local path = path_for(kind)
    if not path then return nil, "unsupported GeoData kind" end
    version = trim(version)
    if version == "" then
        os.remove(path)
        return true
    end

    local ok = os.execute("mkdir -p " .. BASE .. " >/dev/null 2>&1")
    if ok ~= true and ok ~= 0 then return nil, "cannot create " .. BASE end

    local temporary = path .. ".tmp." .. tostring(os.time()) .. "." .. tostring(math.random(100000, 999999))
    local file, err = io.open(temporary, "w")
    if not file then return nil, err or "cannot open temporary version file" end
    if not file:write(version .. "\n") then
        file:close()
        os.remove(temporary)
        return nil, "cannot write temporary version file"
    end
    local closed, close_error = file:close()
    if not closed then
        os.remove(temporary)
        return nil, close_error or "cannot close temporary version file"
    end
    os.execute("chmod 0600 '" .. temporary:gsub("'", "'\\''") .. "' >/dev/null 2>&1")
    if not os.rename(temporary, path) then
        os.remove(temporary)
        return nil, "cannot replace " .. path
    end
    return true
end

return M
