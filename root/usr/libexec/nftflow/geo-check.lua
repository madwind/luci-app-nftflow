#!/usr/bin/lua
-- SPDX-License-Identifier: Apache-2.0
-- GeoData release probe with a short system-wide URL cache.

local jsonc = require "luci.jsonc"
local nixio_fs = require "nixio.fs"
local geodata_version = dofile "/usr/libexec/nftflow/geodata-version.lua"

local UCLIENT_FETCH = "/bin/uclient-fetch"
local CACHE_DIR = "/tmp/openwrt-update-probe"
local CACHE_TTL = 300
local DEFAULT_GEOIP_URL = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
local DEFAULT_GEBSITE_URL = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

local function encode(value) if jsonc.stringify then return jsonc.stringify(value) end return jsonc.encode(value) end
local function decode(value) local f=jsonc.parse or jsonc.decode; local ok,r=pcall(f,value); return ok and r or nil end
local function trim(value) return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function q(value) return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'" end

local function exec_capture(command)
    local pipe=io.popen(command .. " 2>&1")
    if not pipe then return false,"unable to execute command" end
    local output=pipe:read("*a") or ""
    local ok,reason,code=pipe:close()
    if ok==true or code==0 then return true,output end
    return false,trim(output~="" and output or (reason or "command failed"))
end

local function exec_quiet(command) local ok=os.execute(command .. " >/dev/null 2>&1"); return ok==true or ok==0 end
local function read_file(path) local f=io.open(path,"r"); if not f then return nil end local v=f:read("*a"); f:close(); return v end
local function write_file(path,value) local f=io.open(path,"w"); if not f then return false end local ok=f:write(value); local closed=f:close(); return ok~=nil and closed==true end
local function uci_get(option,default) local ok,out=exec_capture("/sbin/uci -q get nftflow.main."..option); out=trim(out); return ok and out~="" and out or default end

local function config(kind)
    local asset_dir=uci_get("asset_dir","/usr/share/xray")
    if kind=="geoip" then return {path=uci_get("geoip_file",asset_dir.."/geoip.dat"),url=uci_get("geoip_url",DEFAULT_GEOIP_URL)} end
    if kind=="geosite" then return {path=uci_get("geosite_file",asset_dir.."/geosite.dat"),url=uci_get("geosite_url",DEFAULT_GEBSITE_URL)} end
end

local function cache_key(url)
    local ok,out=exec_capture("printf '%s' "..q(url).." | sha256sum")
    local key=ok and tostring(out):match("^([0-9A-Fa-f]+)") or nil
    return key and key:lower() or nil
end

local function cache_paths(url)
    local key=cache_key(url)
    if not key then return nil end
    return CACHE_DIR.."/"..key..".json", CACHE_DIR.."/"..key..".lock"
end

local function valid_cached(url)
    local path=cache_paths(url)
    if not path then return nil end
    local stat=nixio_fs.stat(path)
    if type(stat)~="table" or os.time()-(tonumber(stat.mtime) or 0)>CACHE_TTL then return nil end
    local value=decode(read_file(path) or "")
    if type(value)~="table" or value.url~=url or not value.remote_version or not value.download_url or not value.checksum_url then return nil end
    value.cache_hit=true
    return value
end

local function acquire_lock(lock)
    for _=1,50 do
        if exec_quiet("mkdir "..q(lock)) then return true end
        exec_quiet("sleep 0.1")
    end
    return false
end

local function probe_remote(url)
    local cached=valid_cached(url)
    if cached then return cached end
    if not exec_quiet("mkdir -p "..q(CACHE_DIR)) then return {ok=false,url=url,error="cannot create shared update probe cache"} end
    local path,lock=cache_paths(url)
    if not path or not lock then return {ok=false,url=url,error="cannot derive shared update probe cache key"} end
    if not acquire_lock(lock) then return {ok=false,url=url,error="timed out waiting for shared update probe"} end

    cached=valid_cached(url)
    if cached then exec_quiet("rmdir "..q(lock)); return cached end

    local ok,output=exec_capture(q(UCLIENT_FETCH).." -s -T 5 "..q(url))
    if not ok then exec_quiet("rmdir "..q(lock)); return {ok=false,url=url,error=output} end

    local final_url=tostring(output or ""):match("(https://[^%s]+/releases/download/[^%s]+)")
    local remote=(final_url or tostring(output or "")):match("/releases/download/([^/%s]+)/")
    local download_url=final_url
    if download_url then download_url=download_url:gsub("[\r\n].*$","") end
    if not download_url and remote then
        download_url=url:gsub("/releases/latest/download/", "/releases/download/"..remote.."/")
    end
    if not remote or not download_url then
        exec_quiet("rmdir "..q(lock))
        return {ok=false,url=url,error="unable to determine GeoData release version or pinned download URL"}
    end

    local value={
        ok=true,
        url=url,
        remote_version=remote,
        download_url=download_url,
        checksum_url=download_url..".sha256sum",
        checked=os.time(),
        cache_hit=false
    }
    local tmp=path.."."..tostring(os.time()).."."..tostring(math.random(1000,9999))
    if write_file(tmp,encode(value).."\n") then exec_quiet("chmod 0644 "..q(tmp)); os.rename(tmp,path) else os.remove(tmp) end
    exec_quiet("rmdir "..q(lock))
    return value
end

local kind=arg[1]
local asset=config(kind)
local result
if not asset then
    result={ok=false,kind=kind,error="unsupported GeoData kind"}
elseif not asset.url:match("^https://") then
    result={ok=false,kind=kind,url=asset.url,error="GeoData source URL must use HTTPS"}
elseif not nixio_fs.access(UCLIENT_FETCH,"x") then
    result={ok=false,kind=kind,url=asset.url,error="uclient-fetch is unavailable"}
else
    local remote=probe_remote(asset.url)
    if remote.ok~=true then
        result={ok=false,kind=kind,url=asset.url,error=remote.error or "GeoData release probe failed"}
    else
        local stat=nixio_fs.stat(asset.path)
        local ready=type(stat)=="table" and (tonumber(stat.size) or 0)>=1024
        local local_version=ready and geodata_version.read(kind) or nil
        result={
            ok=true,
            kind=kind,
            url=asset.url,
            local_version=local_version,
            remote_version=remote.remote_version,
            download_url=remote.download_url,
            checksum_url=remote.checksum_url,
            update_available=(not local_version) or remote.remote_version~=local_version,
            cache_hit=remote.cache_hit==true
        }
    end
end

io.write(encode(result).."\n")
os.exit(result.ok==false and 1 or 0)
