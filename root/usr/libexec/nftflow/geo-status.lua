#!/usr/bin/lua
-- SPDX-License-Identifier: Apache-2.0
-- Current GeoData file/runtime status only; update operations live in geo-update.lua.

local jsonc = require "luci.jsonc"
local nixio = require "nixio"
local nixio_fs = require "nixio.fs"
local geodata_version = dofile "/usr/libexec/nftflow/geodata-version.lua"

local RUNTIME = "/var/run/nftflow"
local DEFAULT_GEOIP_URL = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
local DEFAULT_GEBSITE_URL = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
local sequence = 0

local function encode(value) if jsonc.stringify then return jsonc.stringify(value) end return jsonc.encode(value) end
local function decode(value) local decoder=jsonc.parse or jsonc.decode; local ok,result=pcall(decoder,value); return ok and result or nil end
local function trim(value) return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function shellquote(value) return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'" end
local function exec_capture(command)
    local pipe=io.popen(command .. " 2>&1"); if not pipe then return false,"" end
    local output=pipe:read("*a") or ""; local ok,_,code=pipe:close(); return ok==true or code==0,output
end
local function exec_quiet(command) local ok=os.execute(command .. " >/dev/null 2>&1"); return ok==true or ok==0 end
local function uci_get(option, default) local ok,output=exec_capture("/sbin/uci -q get nftflow.main."..option); output=trim(output); return ok and output~="" and output or default end
local function read_file(path) local file=io.open(path,"r"); if not file then return nil end; local value=file:read("*a"); file:close(); return value end
local function write_atomic(path,value)
    sequence=sequence+1
    local seconds,microseconds=nixio.gettimeofday()
    local temporary=string.format("%s.tmp.%d.%d.%d.%d",path,nixio.getpid(),seconds,microseconds or 0,sequence)
    local file=io.open(temporary,"w"); if not file then return false end
    if not file:write(value) then file:close(); os.remove(temporary); return false end
    if not file:close() then os.remove(temporary); return false end
    exec_quiet("chmod 0600 "..shellquote(temporary))
    if not os.rename(temporary,path) then os.remove(temporary); return false end
    return true
end
local function state_path(kind) return RUNTIME.."/geo-update-"..kind..".json" end
local function lock_path(kind) return RUNTIME.."/geo-update-"..kind..".lock" end
local function process_alive(pid) pid=tonumber(pid); return pid and pid>1 and exec_quiet("kill -0 "..tostring(math.floor(pid))) end
local function update_state(kind)
    local path=state_path(kind)
    local raw=read_file(path)
    local value=raw and decode(raw) or nil
    if type(value)~="table" then return {kind=kind,status="idle"} end
    value.kind=kind
    if (value.status=="starting" or value.status=="running" or value.status=="stopping") and value.pid and not process_alive(value.pid) then
        value.ok=false
        value.status="failed"
        value.phase="failed"
        value.finished=os.time()
        value.pid=nil
        value.updated=false
        value.error="GeoData update worker exited unexpectedly"
        write_atomic(path,encode(value).."\n")
        exec_quiet("rmdir "..shellquote(lock_path(kind)))
    end
    return value
end

local function asset(kind)
    local asset_dir=uci_get("asset_dir","/usr/share/xray")
    local path=kind=="geoip" and uci_get("geoip_file",asset_dir.."/geoip.dat") or uci_get("geosite_file",asset_dir.."/geosite.dat")
    local url=kind=="geoip" and uci_get("geoip_url",DEFAULT_GEOIP_URL) or uci_get("geosite_url",DEFAULT_GEBSITE_URL)
    local stat=nixio_fs.stat(path)
    local exists=type(stat)=="table"
    local size=exists and tonumber(stat.size) or 0
    local state=update_state(kind)
    local local_version=exists and size>=1024 and (geodata_version.read(kind) or state.local_version or state.source_version) or nil
    local available=nil
    if state.check_ok==true then available=state.update_available end
    return {
        kind=kind,path=path,url=url,exists=exists,size=size,mtime=exists and tonumber(stat.mtime) or nil,
        ready=exists and size>=1024,local_version=local_version,checked=tonumber(state.checked),check_ok=state.check_ok,
        latest_version=state.latest_version,update_available=available,last_check_error=state.last_check_error,
        last_update=tonumber(state.last_update) or (state.updated==true and tonumber(state.finished) or nil),
        post_check_error=state.post_check_error,update=state
    }
end

local assets={geoip=asset("geoip"),geosite=asset("geosite")}
local active={}
for _,kind in ipairs({"geoip","geosite"}) do
    local state=assets[kind].update
    if state.status=="starting" or state.status=="running" or state.status=="stopping" then active[#active+1]=state end
end
local update={ok=true,status="idle"}
if #active==1 then update=active[1] elseif #active>1 then update={ok=true,status="running",kind="all"} end
io.write(encode({ok=true,ready=assets.geoip.ready and assets.geosite.ready,assets=assets,update=update}).."\n")
