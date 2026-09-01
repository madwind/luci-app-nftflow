-- SPDX-License-Identifier: Apache-2.0
-- Persist installed GeoData release versions beside the configured assets.

local M = {}
local DEFAULT_ASSET_DIR = "/usr/share/xray"

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shellquote(value)
    return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function valid_kind(kind)
    return kind == "geoip" or kind == "geosite"
end

local function exec_capture(command)
    local pipe = io.popen(command .. " 2>/dev/null")
    if not pipe then return nil end
    local output = pipe:read("*a") or ""
    pipe:close()
    output = trim(output)
    return output ~= "" and output or nil
end

local function uci_get(option)
    return exec_capture("/sbin/uci -q get nftflow.main." .. option)
end

local function asset_path(kind)
    if not valid_kind(kind) then return nil end
    local asset_dir = trim(uci_get("asset_dir") or DEFAULT_ASSET_DIR)
    if asset_dir == "" then asset_dir = DEFAULT_ASSET_DIR end
    local configured = trim(uci_get(kind .. "_file") or "")
    if configured ~= "" then return configured end
    return asset_dir .. "/" .. kind .. ".dat"
end

local function path_for(kind)
    local asset = asset_path(kind)
    return asset and (asset .. ".version") or nil
end

local function dirname(path)
    return tostring(path):match("^(.*)/[^/]*$") or "."
end

local function mkdirp(path)
    local ok = os.execute("mkdir -p " .. shellquote(path) .. " >/dev/null 2>&1")
    return ok == true or ok == 0
end

local function read_value(path)
    if not path then return nil end
    local file = io.open(path, "r")
    if not file then return nil end
    local value = trim(file:read("*a"))
    file:close()
    return value ~= "" and value or nil
end

local function write_value(path, version)
    version = trim(version)
    if version == "" then
        os.remove(path)
        return true
    end

    local directory = dirname(path)
    if not mkdirp(directory) then return nil, "cannot create " .. directory end

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
    os.execute("chmod 0644 " .. shellquote(temporary) .. " >/dev/null 2>&1")
    if not os.rename(temporary, path) then
        os.remove(temporary)
        return nil, "cannot replace " .. path
    end
    os.execute("chmod 0644 " .. shellquote(path) .. " >/dev/null 2>&1")
    return true
end

function M.read(kind)
    return read_value(path_for(kind))
end

function M.write(kind, version)
    local path = path_for(kind)
    if not path then return nil, "unsupported GeoData kind" end
    return write_value(path, version)
end

return M
