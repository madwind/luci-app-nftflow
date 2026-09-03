#!/usr/bin/lua
-- SPDX-License-Identifier: Apache-2.0
-- Explicit GeoData checks; update workers only consume a pinned checked target.

local jsonc = require "luci.jsonc"
local nixio = require "nixio"
local fs = require "nixio.fs"
local version = dofile "/usr/libexec/nftflow/geodata-version.lua"

local RUNTIME="/var/run/nftflow"
local LOG_DIR="/var/log/nftflow"
local FETCH="/bin/uclient-fetch"
local CHECKER="/usr/libexec/nftflow/geo-check.lua"
local CTL="/usr/libexec/nftflow/nftflowctl"
local GEOIP="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
local GEOSITE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
local seq=0

local function enc(v) if jsonc.stringify then return jsonc.stringify(v) end return jsonc.encode(v) end
local function dec(v) local f=jsonc.parse or jsonc.decode; local ok,r=pcall(f,v); return ok and r or nil end
local function trim(v) return (tostring(v or ""):gsub("^%s+",""):gsub("%s+$","")) end
local function q(v) return "'"..tostring(v or ""):gsub("'","'\\''").."'" end
local function run(c) local p=io.popen(c.." 2>&1"); if not p then return false,"unable to execute command" end local o=p:read("*a") or ""; local ok,why,code=p:close(); return ok==true or code==0,o~="" and o or tostring(why or "command failed") end
local function quiet(c) local ok=os.execute(c.." >/dev/null 2>&1"); return ok==true or ok==0 end
local function read(path) local f=io.open(path,"r"); if not f then return nil end local v=f:read("*a"); f:close(); return v end
local function mkdir(path) if fs.mkdirr then return fs.mkdirr(path) end return quiet("mkdir -p "..q(path)) end
local function temp(base) seq=seq+1; local s,u=nixio.gettimeofday(); return string.format("%s.tmp.%d.%d.%d.%d",base,nixio.getpid(),s,u or 0,seq) end
local function atomic(path,value)
    local t=temp(path); local f,e=io.open(t,"w"); if not f then return false,e end
    if not f:write(value) then f:close(); os.remove(t); return false,"write failed" end
    if not f:close() then os.remove(t); return false,"close failed" end
    quiet("chmod 0600 "..q(t)); if not os.rename(t,path) then os.remove(t); return false,"replace failed" end; return true
end
local function uci(opt,def) local ok,o=run("/sbin/uci -q get nftflow.main."..opt); o=trim(o); return ok and o~="" and o or def end
local function cfg(kind)
    local dir=uci("asset_dir","/usr/share/xray")
    if kind=="geoip" then return {path=uci("geoip_file",dir.."/geoip.dat"),url=uci("geoip_url",GEOIP)} end
    if kind=="geosite" then return {path=uci("geosite_file",dir.."/geosite.dat"),url=uci("geosite_url",GEOSITE)} end
end
local function dirname(path) return tostring(path):match("^(.*)/[^/]*$") or "." end
local function state_path(kind) return RUNTIME.."/geo-update-"..kind..".json" end
local function lock_path(kind) return RUNTIME.."/geo-update-"..kind..".lock" end
local function ready(kind) local a=cfg(kind); local s=a and fs.stat(a.path); return type(s)=="table" and (tonumber(s.size) or 0)>=1024 end
local function load(kind)
    local s=dec(read(state_path(kind)) or ""); if type(s)~="table" then s={kind=kind,status="idle"} end; s.kind=kind
    if ready(kind) then local v=version.read(kind); if v then s.local_version=v; s.source_version=v end else s.local_version=nil; s.source_version=nil end
    return s
end
local function save(kind,s) s.kind=kind; mkdir(RUNTIME); return atomic(state_path(kind),enc(s).."\n") end
local function alive(pid) pid=tonumber(pid); return pid and pid>1 and quiet("kill -0 "..tostring(math.floor(pid))) end
local function active(s) return s and (s.status=="starting" or s.status=="running" or s.status=="stopping") and alive(s.pid) end
local function unlock(kind) quiet("rmdir "..q(lock_path(kind))) end
local function last_update(s) return tonumber(s.last_update) or (s.updated==true and tonumber(s.finished) or nil) end
local function result_from(output) local last; for line in tostring(output or ""):gmatch("[^\r\n]+") do if trim(line)~="" then last=trim(line) end end return last and dec(last) or nil end

local function nftflow_running()
    local ok,out=run(q(CTL).." status")
    local r=result_from(out)
    return ok and type(r)=="table" and r.ok==true and r.running==true
end

local function wait_nftflow_running()
    local stable=0
    for _=1,6 do
        if nftflow_running() then
            stable=stable+1
            if stable>=3 then return true end
        else
            stable=0
        end
        quiet("sleep 1")
    end
    return false
end

local function restore_local(kind,a,backup,had_previous,old_version,s)
    os.remove(a.path)
    if had_previous then
        if not os.rename(backup,a.path) then return false,"cannot restore previous GeoData file" end
        quiet("chmod 0644 "..q(a.path))
    else
        os.remove(backup)
    end
    local restored,err=version.write(kind,old_version or "")
    if not restored then return false,err or "cannot restore previous GeoData version" end
    s.local_version=old_version; s.source_version=old_version
    return true
end

local function check(kind)
    if not cfg(kind) then return {ok=false,kind=kind,error="unsupported GeoData kind"} end
    if not mkdir(RUNTIME) then return {ok=false,kind=kind,error="cannot create GeoData runtime directory"} end
    local s=load(kind); if active(s) then return {ok=false,kind=kind,error="a GeoData update is already in progress"} end
    local ok,out=run("/usr/bin/lua "..q(CHECKER).." "..q(kind)); local r=result_from(out)
    if type(r)~="table" then r={ok=false,kind=kind,error=ok and "GeoData checker returned invalid JSON" or trim(out)} end
    s.status="idle"; s.phase=nil; s.progress=nil; s.error=nil; s.updated=false; s.checked=os.time(); s.check_ok=r.ok==true; s.last_update=last_update(s)
    if r.ok==true then
        s.local_version=r.local_version; s.source_version=r.local_version; s.latest_version=r.remote_version; s.download_url=r.download_url; s.checksum_url=r.checksum_url; s.source_url=r.url
        s.update_available=r.update_available==true; s.cache_hit=r.cache_hit==true; s.last_check_error=nil
    else s.last_check_error=r.error or "GeoData check failed" end
    save(kind,s); r.checked=s.checked; r.check_ok=s.check_ok; r.last_check_error=s.last_check_error; r.last_update=s.last_update; return r
end

local function fail(kind,s,msg)
    s.ok=false; s.status="failed"; s.phase="failed"; s.finished=os.time(); s.pid=nil; s.updated=false; s.error=msg or "GeoData update failed"; save(kind,s); unlock(kind); return s
end

local function worker(kind)
    local a=cfg(kind); if not a then return {ok=false,kind=kind,error="unsupported GeoData kind"} end
    local defer_restart=os.getenv("NFTFLOW_DEFER_RESTART")=="1"
    local was_running=not defer_restart and nftflow_running()
    local s=load(kind); s.pid=nixio.getpid(); s.status="running"; s.phase="starting"; save(kind,s)
    if s.check_ok~=true or s.update_available~=true or not s.latest_version or not s.download_url or not s.checksum_url then return fail(kind,s,"no complete checked GeoData update is available; check updates first") end
    if not mkdir(dirname(a.path)) then return fail(kind,s,"cannot create "..dirname(a.path)) end

    local expected_version=s.latest_version
    local download=temp(a.path..".nftflow-download")
    local checksum=temp(a.path..".nftflow-sha256")
    s.phase="downloading"; s.message="Downloading checked GeoData release and SHA256"; save(kind,s)
    local ok,out=run(q(FETCH).." -T 30 -O "..q(download).." "..q(s.download_url))
    if not ok then os.remove(download); return fail(kind,s,"GeoData download failed: "..trim(out)) end
    ok,out=run(q(FETCH).." -T 15 -O "..q(checksum).." "..q(s.checksum_url))
    if not ok then os.remove(download); os.remove(checksum); return fail(kind,s,"GeoData SHA256 download failed: "..trim(out)) end

    s.phase="verifying"; s.message="Verifying GeoData SHA256"; save(kind,s)
    local stat=fs.stat(download)
    if type(stat)~="table" or (tonumber(stat.size) or 0)<1024 then os.remove(download); os.remove(checksum); return fail(kind,s,"downloaded GeoData file is empty or implausibly small") end
    local expected=trim(read(checksum) or ""):match("^([0-9A-Fa-f]+)")
    expected=expected and expected:lower() or nil
    local hash_ok,hash_out=run("sha256sum "..q(download))
    local actual=hash_ok and tostring(hash_out):match("^([0-9A-Fa-f]+)") or nil
    actual=actual and actual:lower() or nil
    os.remove(checksum)
    if not expected or #expected~=64 or not expected:match("^[0-9a-f]+$") or not actual or actual~=expected then
        os.remove(download)
        return fail(kind,s,"GeoData SHA256 verification failed")
    end

    local backup=temp(a.path..".nftflow-backup")
    local previous=fs.stat(a.path)
    local had_previous=type(previous)=="table"
    local old_version=version.read(kind)
    if had_previous and not os.rename(a.path,backup) then os.remove(download); return fail(kind,s,"cannot preserve previous GeoData file") end
    if not os.rename(download,a.path) then
        if had_previous then os.rename(backup,a.path) end
        os.remove(download)
        return fail(kind,s,"cannot atomically replace "..a.path)
    end
    quiet("chmod 0644 "..q(a.path))

    local persisted,err=version.write(kind,expected_version)
    if not persisted or version.read(kind)~=expected_version then
        local restored,restore_error=restore_local(kind,a,backup,had_previous,old_version,s)
        return fail(kind,s,restored and (err or "installed GeoData version metadata failed local verification") or ("GeoData metadata update failed and rollback failed: "..tostring(restore_error)))
    end

    if was_running then
        s.phase="restarting"; s.message="Restarting NftFlow once to load updated GeoData"; save(kind,s)
        local restarted=quiet("/etc/init.d/nftflow restart")
        if not restarted or not wait_nftflow_running() then
            quiet("/etc/init.d/nftflow stop")
            local restored,restore_error=restore_local(kind,a,backup,had_previous,old_version,s)
            if restored then
                local recovered=quiet("/etc/init.d/nftflow start") and wait_nftflow_running()
                if not recovered then quiet("/etc/init.d/nftflow stop") end
                return fail(kind,s,recovered and "NftFlow rejected updated GeoData; previous GeoData was restored" or "NftFlow rejected updated GeoData; previous GeoData was restored but service recovery also failed")
            end
            return fail(kind,s,"NftFlow failed after GeoData update and rollback failed: "..tostring(restore_error))
        end
    end

    os.remove(backup)
    s.ok=true; s.status="done"; s.phase="done"; s.finished=os.time(); s.pid=nil; s.updated=true; s.local_version=expected_version; s.source_version=expected_version; s.latest_version=expected_version
    s.update_available=false; s.last_update=s.finished; s.post_check_error=nil; s.error=nil; s.message=kind.." updated successfully"; save(kind,s); unlock(kind); return s
end

local function start(kind)
    if not cfg(kind) then return {ok=false,kind=kind,error="unsupported GeoData kind"} end
    if not mkdir(RUNTIME) or not mkdir(LOG_DIR) then return {ok=false,kind=kind,error="cannot create GeoData runtime directory"} end
    local s=load(kind); if active(s) then s.ok=true; return s end
    if s.check_ok~=true or s.update_available~=true or not s.latest_version or not s.download_url or not s.checksum_url then return {ok=false,kind=kind,error="no complete checked GeoData update is available; run Check updates first"} end
    unlock(kind); if not quiet("mkdir "..q(lock_path(kind))) then return {ok=false,kind=kind,status="busy",error="another GeoData update is starting"} end
    s.ok=true; s.status="starting"; s.phase="starting"; s.started=os.time(); s.finished=nil; s.pid=nil; s.updated=false; s.post_check_error=nil; s.error=nil; s.message="GeoData update started"; save(kind,s)
    local log=LOG_DIR.."/geo-update-"..kind..".log"; local cmd=string.format("/usr/bin/lua /usr/libexec/nftflow/geo-update.lua worker %s </dev/null >>%s 2>&1 & echo $!",q(kind),q(log))
    local p=io.popen(cmd,"r"); local pid=p and tonumber(trim(p:read("*l") or "")) or nil; if p then p:close() end
    if not pid then unlock(kind); s.ok=false; s.status="failed"; s.phase="failed"; s.error="unable to start GeoData update worker"; save(kind,s); return s end
    s.pid=pid; save(kind,s); return s
end

local function normalize(kind,s)
    if (s.status=="starting" or s.status=="running" or s.status=="stopping") and s.pid and not alive(s.pid) then s.ok=false; s.status="failed"; s.phase="failed"; s.finished=os.time(); s.pid=nil; s.updated=false; s.error="GeoData update worker exited unexpectedly"; save(kind,s); unlock(kind) end
    return s
end
local function status()
    local assets={}; for _,kind in ipairs({"geoip","geosite"}) do local s=normalize(kind,load(kind)); assets[kind]={kind=kind,local_version=s.local_version or s.source_version,checked=tonumber(s.checked),check_ok=s.check_ok,latest_version=s.latest_version,update_available=s.update_available,last_check_error=s.last_check_error,last_update=last_update(s),post_check_error=s.post_check_error,update=s} end
    return {ok=true,assets=assets}
end

local command=arg[1] or ""; local r
if command=="check" then r=check(arg[2]) elseif command=="start" then r=start(arg[2]) elseif command=="worker" then r=worker(arg[2]) elseif command=="status" then r=status() else r={ok=false,error="unknown GeoData update command"} end
io.write(enc(r).."\n"); os.exit(r.ok==false and 1 or 0)
