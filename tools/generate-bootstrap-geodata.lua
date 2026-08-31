#!/usr/bin/lua
-- SPDX-License-Identifier: Apache-2.0
-- Generate minimal Xray GeoData assets from the packaged default config.
-- This runs only while building the APK. Runtime never synthesizes GeoData.

local config_path = arg[1]
local geoip_seed_path = arg[2]
local geoip_output_path = arg[3]
local geosite_output_path = arg[4]

if not config_path or not geoip_seed_path or not geoip_output_path or not geosite_output_path then
    io.stderr:write("usage: generate-bootstrap-geodata.lua <config.json> <geoip-seed.dat> <geoip-out.dat> <geosite-out.dat>\n")
    os.exit(2)
end

local function read_file(path, mode)
    local file, err = io.open(path, mode or "rb")
    if not file then error(err or ("cannot open " .. path)) end
    local value = file:read("*a")
    file:close()
    return value
end

local function write_file(path, value)
    local file, err = io.open(path, "wb")
    if not file then error(err or ("cannot open " .. path)) end
    local ok, write_err = file:write(value)
    if not ok then
        file:close()
        error(write_err or ("cannot write " .. path))
    end
    local closed, close_err = file:close()
    if not closed then error(close_err or ("cannot close " .. path)) end
end

local function varint(value)
    value = tonumber(value)
    if not value or value < 0 then error("invalid protobuf varint") end
    local out = {}
    repeat
        local byte = value % 128
        value = math.floor(value / 128)
        if value > 0 then byte = byte + 128 end
        out[#out + 1] = string.char(byte)
    until value == 0
    return table.concat(out)
end

local function bytes_field(field, value)
    return varint(field * 8 + 2) .. varint(#value) .. value
end

local function varint_field(field, value)
    return varint(field * 8) .. varint(value)
end

local function read_varint(data, position)
    local value, multiplier = 0, 1
    for _ = 1, 10 do
        local byte = data:byte(position)
        if not byte then return nil, nil, "unexpected end of protobuf varint" end
        position = position + 1
        value = value + (byte % 128) * multiplier
        if byte < 128 then return value, position end
        multiplier = multiplier * 128
    end
    return nil, nil, "invalid protobuf varint"
end

local function skip_wire(data, position, wire)
    if wire == 0 then
        local _, next_position, err = read_varint(data, position)
        return next_position, err
    elseif wire == 1 then
        if position + 7 > #data then return nil, "truncated protobuf fixed64" end
        return position + 8
    elseif wire == 2 then
        local length, next_position, err = read_varint(data, position)
        if not length then return nil, err end
        local finish = next_position + length
        if finish - 1 > #data then return nil, "truncated protobuf bytes" end
        return finish
    elseif wire == 5 then
        if position + 3 > #data then return nil, "truncated protobuf fixed32" end
        return position + 4
    end
    return nil, "unsupported protobuf wire type " .. tostring(wire)
end

local function message_code(body)
    local position = 1
    while position <= #body do
        local key, next_position, err = read_varint(body, position)
        if not key then error(err) end
        position = next_position
        local field, wire = math.floor(key / 8), key % 8
        if field == 1 and wire == 2 then
            local length, content_position
            length, content_position, err = read_varint(body, position)
            if not length then error(err) end
            local finish = content_position + length - 1
            if finish > #body then error("truncated GeoData code") end
            return string.upper(body:sub(content_position, finish))
        end
        position, err = skip_wire(body, position, wire)
        if not position then error(err) end
    end
    return nil
end

local function top_level_codes(data)
    local result = {}
    local position = 1
    while position <= #data do
        local key, next_position, err = read_varint(data, position)
        if not key then error(err) end
        position = next_position
        local field, wire = math.floor(key / 8), key % 8
        if field == 1 and wire == 2 then
            local length, content_position
            length, content_position, err = read_varint(data, position)
            if not length then error(err) end
            local finish = content_position + length - 1
            if finish > #data then error("truncated GeoData entry") end
            local code = message_code(data:sub(content_position, finish))
            if code and code ~= "" then result[code] = true end
            position = finish + 1
        else
            position, err = skip_wire(data, position, wire)
            if not position then error(err) end
        end
    end
    return result
end

local function strip_reverse(value)
    while value:sub(1, 1) == "!" do value = value:sub(2) end
    return value
end

local function collect_codes(config)
    local geoip, geosite = {}, {}

    for value in config:gmatch('"([^"\\]*)"') do
        value = strip_reverse(value)

        local ip_code = value:match("^geoip:(.+)$")
        if ip_code then
            ip_code = strip_reverse(ip_code)
            if ip_code ~= "" then geoip[string.upper(ip_code)] = true end
        end

        local site_code = value:match("^geosite:(.+)$")
        if site_code then
            site_code = strip_reverse(site_code)
            site_code = site_code:match("^([^@]+)") or site_code
            if site_code ~= "" then geosite[string.upper(site_code)] = true end
        end
    end

    return geoip, geosite
end

local function sorted_keys(values)
    local result = {}
    for value in pairs(values) do result[#result + 1] = value end
    table.sort(result)
    return result
end

local function geoip_entry(code)
    return bytes_field(1, code)
end

local function domain_entry(value)
    -- Domain.Type = Domain (2): match the domain itself and its subdomains.
    return varint_field(1, 2) .. bytes_field(2, value)
end

local BOOTSTRAP_SITE_DOMAINS = {
    ["CATEGORY-DEV"] = {
        "github.com",
        "githubusercontent.com",
        "openwrt.com"
    }
}

local function geosite_entry(code)
    local body = bytes_field(1, code)
    local domains = BOOTSTRAP_SITE_DOMAINS[code] or {}
    for _, domain in ipairs(domains) do
        body = body .. bytes_field(2, domain_entry(domain))
    end
    return body
end

local config = read_file(config_path, "rb")
local required_geoip, required_geosite = collect_codes(config)
if not next(required_geoip) then error("default config does not reference any geoip: entries") end
if not next(required_geosite) then error("default config does not reference any geosite: entries") end

local geoip_seed = read_file(geoip_seed_path, "rb")
local existing_geoip = top_level_codes(geoip_seed)
local geoip_output = geoip_seed
for _, code in ipairs(sorted_keys(required_geoip)) do
    if not existing_geoip[code] then
        geoip_output = geoip_output .. bytes_field(1, geoip_entry(code))
    end
end
write_file(geoip_output_path, geoip_output)

local geosite_output = ""
for _, code in ipairs(sorted_keys(required_geosite)) do
    geosite_output = geosite_output .. bytes_field(1, geosite_entry(code))
end
write_file(geosite_output_path, geosite_output)

io.stdout:write("bootstrap GeoIP: " .. table.concat(sorted_keys(required_geoip), ", ") .. "\n")
io.stdout:write("bootstrap GeoSite: " .. table.concat(sorted_keys(required_geosite), ", ") .. "\n")
