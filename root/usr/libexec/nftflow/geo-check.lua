#!/usr/bin/lua
-- SPDX-License-Identifier: Apache-2.0
-- Lightweight GeoData release check used internally by geo-update.lua.

local jsonc = require "luci.jsonc"
local nixio_fs = require "nixio.fs"
local geodata_version = dofile "/usr/libexec/nftflow/geodata-version.lua"

local UCLIENT_FETCH = "/bin/uclient-fetch"
local DEFAULT_GEOIP_URL = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
local DEFAULT_GEBSITE_URL = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

local function encode(value) if jsonc.stringify then return jsonc.stringify(value) end; return jsonc.encode(value) end
local function trim(value) return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function q(value) return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'" end
local function exec_capture(command)
    local pipe=io.popen(command .. " 2>&1"); if not pipe then return false,"unable to execute command" end
    local output=pipe:read("*a") or ""; local ok,reason,code=pipe:close(); if ok==true or code==0 then return true,output end
    return false,trim(output~="" and output or (reason or "command failed"))
end
local function uci_get(option, default) local ok,output=exec_capture("/sbin/uci -q get nftflow.main."..option); output=trim(output); return ok and output~="" and output or default end
local function config(kind)
    local asset_dir=uci_get("asset_dir","/usr/share/xray")
    if kind=="geoip" then return {path=uci_get("geoip_file",asset_dir.."/geoip.dat"),url=uci_get("geoip_url",DEFAULT_GEOIP_URL)} end
    if kind=="geosite" then return {path=uci_get("geosite_file",asset_dir.."/geosite.dat"),url=uci_get("geosite_url",DEFAULT_GEBSITE_URL)} end
end

local kind=arg[1]; local asset=config(kind); local result
if not asset then result={ok=false,kind=kind,error="unsupported GeoData kind"}
elseif not asset.url:match("^https://") then result={ok=false,kind=kind,url=asset.url,error="GeoData source URL must use HTTPS"}
elseif not nixio_fs.access(UCLIENT_FETCH,"x") then result={ok=false,kind=kind,url=asset.url,error="uclient-fetch is unavailable"}
else
    local ok,output=exec_capture(UCLIENT_FETCH.." -s -T 5 "..q(asset.url))
    if not ok then result={ok=false,kind=kind,url=asset.url,error=output}
    else
        local remote=tostring(output or ""):match("/releases/download/([^/%s]+)/"); local stat=nixio_fs.stat(asset.path)
        local local_version=stat and (tonumber(stat.size) or 0)>=1024 and geodata_version.read(kind) or nil
        result={ok=true,kind=kind,url=asset.url,local_version=local_version,remote_version=remote,update_available=remote and local_version and remote~=local_version or nil}
    end
end
io.write(encode(result).."\n"); os.exit(result.ok==false and 1 or 0)
