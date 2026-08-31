-- SPDX-License-Identifier: Apache-2.0
-- Prepare a temporary Xray configuration when restored configs reference
-- GeoIP/GeoSite tags that are not present in the installed GeoData files.
-- The saved user configuration and GeoData files are never modified.

local jsonc = require "luci.jsonc"

local M = {}

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

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local value = file:read("*a")
    file:close()
    return value
end

local function write_file(path, value)
    local file, err = io.open(path, "w")
    if not file then return nil, err end
    local written, write_error = file:write(value)
    if not written then file:close(); return nil, write_error end
    local closed, close_error = file:close()
    if not closed then return nil, close_error end
    return true
end

local function read_varint_file(file)
    local value, multiplier = 0, 1
    for _ = 1, 10 do
        local raw = file:read(1)
        if not raw then return nil, "unexpected end of GeoData varint" end
        local byte = raw:byte()
        value = value + (byte % 128) * multiplier
        if byte < 128 then return value end
        multiplier = multiplier * 128
    end
    return nil, "invalid GeoData varint"
end

local function read_varint(data, position)
    local value, multiplier = 0, 1
    for _ = 1, 10 do
        local byte = data:byte(position)
        if not byte then return nil, nil, "unexpected end of GeoData entry" end
        position = position + 1
        value = value + (byte % 128) * multiplier
        if byte < 128 then return value, position end
        multiplier = multiplier * 128
    end
    return nil, nil, "invalid GeoData varint"
end

local function entry_code(prefix)
    local key, position, err = read_varint(prefix, 1)
    if key == nil then return nil, err end
    if math.floor(key / 8) ~= 1 or key % 8 ~= 2 then
        return nil, "GeoData entry does not start with a code field"
    end
    local length
    length, position, err = read_varint(prefix, position)
    if length == nil then return nil, err end
    local finish = position + length - 1
    if finish > #prefix then return nil, "GeoData code is truncated" end
    return string.upper(prefix:sub(position, finish))
end

local function scan_codes(path)
    local file = io.open(path, "rb")
    if not file then return {}, false end

    local codes = {}
    while true do
        local marker = file:read(1)
        if not marker then break end
        if marker:byte() ~= 10 then
            file:close()
            return nil, true, "unsupported GeoData structure in " .. path
        end

        local length, length_error = read_varint_file(file)
        if length == nil then
            file:close()
            return nil, true, length_error
        end
        if length < 1 or length > 128 * 1024 * 1024 then
            file:close()
            return nil, true, "invalid GeoData entry length in " .. path
        end

        local prefix_length = math.min(length, 512)
        local prefix = file:read(prefix_length)
        if not prefix or #prefix ~= prefix_length then
            file:close()
            return nil, true, "truncated GeoData entry in " .. path
        end

        local code, code_error = entry_code(prefix)
        if not code then
            file:close()
            return nil, true, code_error
        end
        codes[code] = true

        local remaining = length - prefix_length
        if remaining > 0 and not file:seek("cur", remaining) then
            file:close()
            return nil, true, "cannot seek through " .. path
        end
    end

    file:close()
    return codes, true
end

local function strip_leading_bang(value)
    value = tostring(value or "")
    while value:sub(1, 1) == "!" do value = value:sub(2) end
    return value
end

local function replacement_for(value, geoip_codes, geosite_codes)
    local geoip = value:match("^geoip:(.+)$")
    if geoip then
        local lookup = strip_leading_bang(geoip)
        if lookup ~= "" and not geoip_codes[string.upper(lookup)] then
            if string.upper(lookup) == "PRIVATE" then
                return nil, "required geoip:private is missing from the installed GeoIP database"
            end
            if not geoip_codes.PRIVATE then
                return nil, "cannot replace " .. value .. " because geoip:private is unavailable"
            end
            return "geoip:private"
        end
        return value
    end

    local geosite = value:match("^geosite:(.+)$")
    if geosite then
        geosite = strip_leading_bang(geosite)
        local code = geosite:match("^([^@]+)") or geosite
        if code ~= "" and not geosite_codes[string.upper(code)] then
            return "domain:" .. code
        end
    end

    return value
end

local function prepare_value(value, geoip_codes, geosite_codes, replacements, seen)
    if type(value) == "string" then
        local replacement, replacement_error = replacement_for(value, geoip_codes, geosite_codes)
        if not replacement then return nil, replacement_error end
        if replacement ~= value then
            local key = value .. "\0" .. replacement
            if not seen[key] then
                seen[key] = true
                replacements[#replacements + 1] = { from = value, to = replacement }
            end
        end
        return replacement
    end

    if type(value) ~= "table" then return value end
    for key, child in pairs(value) do
        local prepared, prepare_error = prepare_value(child, geoip_codes, geosite_codes, replacements, seen)
        if prepared == nil and prepare_error then return nil, prepare_error end
        value[key] = prepared
    end
    return value
end

function M.prepare(raw, asset_dir)
    raw = tostring(raw or "")
    asset_dir = trim(asset_dir)
    if asset_dir == "" then asset_dir = "/usr/share/xray" end

    local ok, config = pcall(json_decode, raw)
    if not ok or type(config) ~= "table" then return nil, nil, "invalid Xray JSON configuration" end

    local geoip_codes, _, geoip_error = scan_codes(asset_dir .. "/geoip.dat")
    if not geoip_codes then return nil, nil, geoip_error end
    local geosite_codes, _, geosite_error = scan_codes(asset_dir .. "/geosite.dat")
    if not geosite_codes then return nil, nil, geosite_error end

    local replacements, seen = {}, {}
    local prepared, prepare_error = prepare_value(config, geoip_codes, geosite_codes, replacements, seen)
    if not prepared then return nil, nil, prepare_error end

    if #replacements == 0 then return raw, replacements end
    return json_encode(prepared) .. "\n", replacements
end

if tostring(arg and arg[0] or ""):match("geodata%-fallback%.lua$") and arg[1] == "prepare" then
    local source_path, asset_dir, output_path = arg[2], arg[3], arg[4]
    local raw = source_path and read_file(source_path)
    if not raw then
        io.stderr:write("cannot read Xray configuration: " .. tostring(source_path or "") .. "\n")
        os.exit(1)
    end
    local prepared, replacements, prepare_error = M.prepare(raw, asset_dir)
    if not prepared then
        io.stderr:write(tostring(prepare_error or "cannot prepare Xray runtime configuration") .. "\n")
        os.exit(1)
    end
    local saved, save_error = write_file(output_path, prepared)
    if not saved then
        io.stderr:write(tostring(save_error or ("cannot write " .. tostring(output_path))) .. "\n")
        os.exit(1)
    end
    for _, replacement in ipairs(replacements or {}) do
        os.execute("logger -t nftflowctl " .. shellquote(
            "GeoData fallback: " .. replacement.from .. " -> " .. replacement.to))
    end
    io.write(json_encode({ ok = true, path = output_path, replacements = replacements or {} }) .. "\n")
    os.exit(0)
end

return M
