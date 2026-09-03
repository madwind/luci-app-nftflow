#!/usr/bin/lua
-- SPDX-License-Identifier: Apache-2.0
-- Software update checks are explicit. Install workers only consume a cached check result.

local jsonc = require "luci.jsonc"
local nixio = require "nixio"
local nixio_fs = require "nixio.fs"

local UPDATE_DIR = "/tmp/nftflow-update"
local MANIFEST_URL = "https://github.com/madwind/luci-app-nftflow/releases/latest/download/nftflow-update.json"
local RELEASE_BASE = "https://github.com/madwind/luci-app-nftflow/releases/download/"
local UCLIENT_FETCH = "/bin/uclient-fetch"
local sequence = 0

local PACKAGES = { nftflow = "luci-app-nftflow", xray = "xray-core" }

local function encode(value) if jsonc.stringify then return jsonc.stringify(value) end return jsonc.encode(value) end
local function decode(value) local f=jsonc.parse or jsonc.decode; local ok,r=pcall(f,value); return ok and r or nil end
local function trim(value) return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function q(value) return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'" end

local function exec_capture(command)
    local pipe = io.popen(command .. " 2>&1")
    if not pipe then return false, "unable to execute command", 1 end
    local output = pipe:read("*a") or ""
    local ok, reason, code = pipe:close()
    if ok == true or code == 0 then return true, output, 0 end
    return false, trim(output ~= "" and output or (reason or "command failed")), tonumber(code) or 1
end

local function exec_quiet(command) local ok=os.execute(command .. " >/dev/null 2>&1"); return ok==true or ok==0 end
local function mkdirp(path) if nixio_fs and nixio_fs.mkdirr then return nixio_fs.mkdirr(path) end return exec_quiet("mkdir -p " .. q(path)) end
local function read_file(path) local f=io.open(path,"r"); if not f then return nil end local v=f:read("*a"); f:close(); return v end
local function temporary_path(base) sequence=sequence+1; local s,u=nixio.gettimeofday(); return string.format("%s.tmp.%d.%d.%d.%d",base,nixio.getpid(),s,u or 0,sequence) end

local function write_atomic(path, value)
    local tmp=temporary_path(path); local f,err=io.open(tmp,"w"); if not f then return false,err or "cannot open temporary file" end
    if not f:write(value) then f:close(); os.remove(tmp); return false,"cannot write temporary file" end
    local closed,cerr=f:close(); if not closed then os.remove(tmp); return false,cerr or "cannot close temporary file" end
    exec_quiet("chmod 0600 " .. q(tmp)); if not os.rename(tmp,path) then os.remove(tmp); return false,"cannot replace "..path end
    return true
end

local function state_path(kind) return UPDATE_DIR .. "/" .. kind .. ".json" end
local function lock_path(kind) return UPDATE_DIR .. "/" .. kind .. ".lock" end
local function read_state(kind) local v=decode(read_file(state_path(kind)) or ""); if type(v)~="table" then v={kind=kind,status="idle"} end v.kind=kind return v end
local function save_state(kind,state) state.kind=kind; mkdirp(UPDATE_DIR); return write_atomic(state_path(kind),encode(state).."\n") end
local function remove_lock(kind) exec_quiet("rmdir " .. q(lock_path(kind))) end
local function process_alive(pid) pid=tonumber(pid); return pid and pid>1 and exec_quiet("kill -0 "..tostring(math.floor(pid))) end

local function compact_error(output)
    local lines={}; for line in tostring(output or ""):gmatch("[^\r\n]+") do line=trim(line); if line~="" then lines[#lines+1]=line; if #lines>6 then table.remove(lines,1) end end end
    return table.concat(lines," | ")
end

local function parse_package_version(package_name, output)
    local prefix=package_name.."-"
    for line in tostring(output or ""):gmatch("[^\r\n]+") do local token=line:match("^(%S+)"); if token and token:sub(1,#prefix)==prefix then return token:sub(#prefix+1) end end
end

local function installed_version(package_name) local ok,out=exec_capture("apk list -I "..q(package_name)); if not ok then return nil end return parse_package_version(package_name,out) end
local function version_relation(left,right) if not left or not right then return nil end local ok,out=exec_capture("apk version -t "..q(left).." "..q(right)); return ok and trim(out):match("[<=>]") or nil end
local function is_update_available(installed,latest) local r=version_relation(latest,installed); if not r then return nil end return r==">" end

local function newest_version(package_name, output)
    local prefix=package_name.."-", newest=nil
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        local token=line:match("^(%S+)")
        if token and token:sub(1,#prefix)==prefix then local candidate=token:sub(#prefix+1); if not newest or version_relation(candidate,newest)==">" then newest=candidate end end
    end
    return newest
end

local function fetch_file(url,path)
    if not tostring(url or ""):match("^https://") then return false,"download URL must use HTTPS" end
    if not exec_quiet("[ -x "..q(UCLIENT_FETCH).." ]") then return false,"uclient-fetch is unavailable" end
    os.remove(path); local ok,out,code=exec_capture(q(UCLIENT_FETCH).." -T 15 -O "..q(path).." "..q(url)); if ok then return true end
    os.remove(path); local detail=compact_error(out); if detail=="" then detail="uclient-fetch exited with status "..tostring(code) end; return false,detail
end

local function validate_manifest(manifest)
    if type(manifest)~="table" then return false,"update manifest is not valid JSON" end
    local version=trim(manifest.version), tag=trim(manifest.tag), asset=trim(manifest.asset), sha256=trim(manifest.sha256):lower()
    if version=="" or not version:match("^[%w%._+%-]+$") then return false,"update manifest has an invalid version" end
    if tag=="" or not tag:match("^[%w%._+%-]+$") then return false,"update manifest has an invalid tag" end
    if asset=="" or asset:find("/",1,true) or not asset:match("^luci%-app%-nftflow%-.+%.apk$") then return false,"update manifest has an invalid package asset" end
    if not sha256:match("^[0-9a-f]+$") or #sha256~=64 then return false,"update manifest has an invalid SHA256" end
    return true,{version=version,tag=tag,asset=asset,sha256=sha256,url=RELEASE_BASE..tag.."/"..asset}
end

local function probe_nftflow()
    if not mkdirp(UPDATE_DIR) then return {ok=false,kind="nftflow",error="cannot create update directory"} end
    local path=temporary_path(UPDATE_DIR.."/manifest"); local ok,err=fetch_file(MANIFEST_URL,path)
    if not ok then
        if tostring(err):match("404") then return {ok=true,kind="nftflow",installed_version=installed_version(PACKAGES.nftflow),update_available=false,no_release=true} end
        return {ok=false,kind="nftflow",error="NftFlow release check failed: "..tostring(err)}
    end
    local raw=read_file(path) or ""; os.remove(path); local valid,m=validate_manifest(decode(raw)); if not valid then return {ok=false,kind="nftflow",error=m} end
    local installed=installed_version(PACKAGES.nftflow)
    return {ok=true,kind="nftflow",installed_version=installed,latest_version=m.version,update_available=is_update_available(installed,m.version),manifest=m}
end

local function probe_xray()
    local installed=installed_version(PACKAGES.xray); if not installed then return {ok=false,kind="xray",error="xray-core is not installed"} end
    local ok,out=exec_capture("apk update"); if not ok then return {ok=false,kind="xray",error="apk update failed: "..compact_error(out)} end
    ok,out=exec_capture("apk list -a "..q(PACKAGES.xray)); if not ok then return {ok=false,kind="xray",error="unable to list xray-core versions: "..compact_error(out)} end
    local latest=newest_version(PACKAGES.xray,out); if not latest then return {ok=false,kind="xray",error="xray-core is unavailable from configured APK repositories"} end
    return {ok=true,kind="xray",installed_version=installed,latest_version=latest,update_available=is_update_available(installed,latest)}
end

local function last_update(state) local v=tonumber(state and state.last_update); if v then return v end if state and state.updated==true then return tonumber(state.finished) end end

local function check(kind)
    if not PACKAGES[kind] then return {ok=false,kind=kind,error="unsupported update kind"} end
    local current=read_state(kind)
    if (current.status=="starting" or current.status=="running" or current.status=="stopping") and process_alive(current.pid) then return {ok=false,kind=kind,error="an update is already in progress"} end
    local result=kind=="nftflow" and probe_nftflow() or probe_xray()
    local state={ok=true,kind=kind,status="idle",installed_version=current.installed_version,latest_version=current.latest_version,update_available=current.update_available,no_release=current.no_release==true,last_update=last_update(current)}
    state.checked=os.time(); state.check_ok=result.ok==true
    if result.ok==true then
        state.installed_version=result.installed_version or installed_version(PACKAGES[kind]) or state.installed_version
        state.latest_version=result.latest_version; state.update_available=result.update_available; state.no_release=result.no_release==true; state.last_check_error=nil
        if kind=="nftflow" and result.manifest then state.release_tag=result.manifest.tag; state.asset=result.manifest.asset; state.sha256=result.manifest.sha256; state.download_url=result.manifest.url end
    else
        state.installed_version=installed_version(PACKAGES[kind]) or state.installed_version; state.last_check_error=result.error or "update check failed"
    end
    save_state(kind,state)
    result.checked=state.checked; result.check_ok=state.check_ok; result.last_check_error=state.last_check_error; result.last_update=state.last_update
    return result
end

local function set_phase(kind,state,phase,message) state.ok=true; state.status="running"; state.phase=phase; state.message=message; state.pid=nixio.getpid(); save_state(kind,state) end
local function fail_worker(kind,state,message) state.ok=false; state.status="failed"; state.phase="failed"; state.finished=os.time(); state.error=message or "update failed"; state.pid=nil; save_state(kind,state); remove_lock(kind); return state end

local function verify_installed(kind,state,expected)
    local installed=installed_version(PACKAGES[kind]); state.installed_version=installed or state.installed_version; state.post_check_error=nil
    if not installed then state.post_check_error="Unable to verify the installed "..(kind=="nftflow" and "NftFlow" or "xray-core").." version after update."; return false end
    local relation=version_relation(installed,expected)
    if relation=="=" or relation==">" then state.update_available=false; return true end
    if relation=="<" then state.update_available=true; state.post_check_error="The installed version is still older than the checked version."; return false end
    state.post_check_error="Unable to compare the installed version after update."; return false
end

local function done_worker(kind,state,message)
    state.ok=true; state.status="done"; state.phase="done"; state.finished=os.time(); state.updated=true; state.last_update=state.finished; state.error=nil; state.message=message; state.pid=nil
    save_state(kind,state); remove_lock(kind); return state
end

local function worker_nftflow(state)
    if not state.download_url or not state.sha256 or not state.latest_version then return fail_worker("nftflow",state,"cached NftFlow check data is incomplete; check updates again") end
    local path=temporary_path(UPDATE_DIR.."/"..(state.asset or "luci-app-nftflow.apk"))
    set_phase("nftflow",state,"downloading","Downloading checked NftFlow package")
    local ok,err=fetch_file(state.download_url,path); if not ok then return fail_worker("nftflow",state,"NftFlow download failed: "..tostring(err)) end
    set_phase("nftflow",state,"verifying","Verifying NftFlow package")
    local hash_ok,hash_out=exec_capture("sha256sum "..q(path)); local actual=hash_ok and tostring(hash_out):match("^([0-9A-Fa-f]+)") or nil
    if not actual or actual:lower()~=tostring(state.sha256):lower() then os.remove(path); return fail_worker("nftflow",state,"NftFlow SHA256 verification failed") end
    set_phase("nftflow",state,"installing","Installing NftFlow package")
    local install_ok,install_out=exec_capture("apk add --allow-untrusted --upgrade "..q(path)); os.remove(path)
    if not install_ok then return fail_worker("nftflow",state,"NftFlow installation failed: "..compact_error(install_out)) end
    verify_installed("nftflow",state,state.latest_version); return done_worker("nftflow",state,"NftFlow updated successfully")
end

local function worker_xray(state)
    local expected=state.latest_version; if not expected then return fail_worker("xray",state,"cached Xray check data is incomplete; check updates again") end
    local was_running=exec_quiet("/etc/init.d/nftflow running"); if was_running then exec_quiet("/etc/init.d/nftflow stop") end
    set_phase("xray",state,"installing","Installing checked xray-core version")
    local ok,out=exec_capture("apk add --upgrade "..q(PACKAGES.xray.."="..expected))
    if was_running then exec_quiet("/etc/init.d/nftflow start") end
    if not ok then return fail_worker("xray",state,"xray-core installation failed: "..compact_error(out)) end
    verify_installed("xray",state,expected); return done_worker("xray",state,"Xray Core updated successfully")
end

local function worker(kind)
    if not PACKAGES[kind] then return {ok=false,kind=kind,error="unsupported update kind"} end
    local state=read_state(kind); state.pid=nixio.getpid(); state.status="running"; state.phase="starting"; state.started=tonumber(state.started) or os.time(); save_state(kind,state)
    if state.check_ok~=true or state.update_available~=true then return fail_worker(kind,state,"no checked update is available; check updates first") end
    if kind=="nftflow" then return worker_nftflow(state) end return worker_xray(state)
end

local function start(kind)
    if not PACKAGES[kind] then return {ok=false,kind=kind,error="unsupported update kind"} end
    if not mkdirp(UPDATE_DIR) then return {ok=false,kind=kind,error="cannot create update directory"} end
    local current=read_state(kind)
    if (current.status=="starting" or current.status=="running" or current.status=="stopping") and process_alive(current.pid) then current.ok=true; return current end
    if current.check_ok~=true or current.update_available~=true then return {ok=false,kind=kind,error="no checked update is available; run Check updates first"} end
    if kind=="nftflow" and (not current.download_url or not current.sha256 or not current.latest_version) then return {ok=false,kind=kind,error="cached NftFlow check data is incomplete; check updates again"} end
    remove_lock(kind); if not exec_quiet("mkdir "..q(lock_path(kind))) then return {ok=false,kind=kind,status="busy",error="another update is starting"} end
    current.ok=true; current.status="starting"; current.phase="starting"; current.started=os.time(); current.finished=nil; current.pid=nil; current.updated=false; current.post_check_error=nil; current.error=nil; current.message="Update started"; current.installed_version=installed_version(PACKAGES[kind]) or current.installed_version
    local saved,err=save_state(kind,current); if not saved then remove_lock(kind); return {ok=false,kind=kind,status="failed",error=err or "cannot save update state"} end
    local log=UPDATE_DIR.."/"..kind..".log"; local launch=string.format("/usr/bin/lua /usr/libexec/nftflow/update.lua worker %s </dev/null >>%s 2>&1 & echo $!",q(kind),q(log))
    local pipe=io.popen(launch,"r"); local pid=pipe and tonumber(trim(pipe:read("*l") or "")) or nil; if pipe then pipe:close() end
    if not pid then remove_lock(kind); current.ok=false; current.status="failed"; current.phase="failed"; current.error="unable to start update worker"; save_state(kind,current); return current end
    current.pid=pid; save_state(kind,current); return current
end

local function normalize(kind,state)
    if (state.status=="starting" or state.status=="running" or state.status=="stopping") and state.pid and not process_alive(state.pid) then
        state.ok=false; state.status="failed"; state.phase="failed"; state.finished=os.time(); state.error="update worker exited unexpectedly"; state.pid=nil; save_state(kind,state); remove_lock(kind)
    end
    return state
end

local function component_status(kind)
    local state=normalize(kind,read_state(kind)); local installed=installed_version(PACKAGES[kind]); local latest=state.latest_version; local available=latest and is_update_available(installed,latest) or nil
    return {kind=kind,installed_version=installed,latest_version=latest,update_available=available,no_release=state.no_release==true,checked=state.checked,check_ok=state.check_ok,last_check_error=state.last_check_error,last_update=last_update(state),operation=state}
end

local function status() return {ok=true,components={nftflow=component_status("nftflow"),xray=component_status("xray")}} end

local command=arg[1] or ""; local result
if command=="status" then result=status()
elseif command=="check" then result=check(arg[2])
elseif command=="start" then result=start(arg[2])
elseif command=="worker" then result=worker(arg[2])
else result={ok=false,error="unknown update command"} end
io.write(encode(result).."\n"); os.exit(result.ok==false and 1 or 0)
