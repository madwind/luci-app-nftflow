#!/usr/bin/lua
-- SPDX-License-Identifier: Apache-2.0
-- NftFlow policy-routing editor and transactional runtime.

local jsonc = require "luci.jsonc"
local nixio = require "nixio"
local fs = require "nixio.fs"

local SOURCE = "/etc/nftflow/routing.conf"
local RUNTIME = "/var/run/nftflow"
local APPLIED = RUNTIME .. "/routing.applied.conf"
local CANDIDATE = RUNTIME .. "/routing.candidate.conf"
local LEGACY_OWNERSHIP = RUNTIME .. "/routing.ownership.json"
local MAX = 32 * 1024
local seq = 0

local function encode(v) return jsonc.stringify and jsonc.stringify(v) or jsonc.encode(v) end
local function trim(v) return (tostring(v or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function q(v) return "'" .. tostring(v or ""):gsub("'", "'\\''") .. "'" end
local function run(cmd)
    local p=io.popen(cmd .. " 2>&1"); if not p then return false,"unable to execute command" end
    local out=p:read("*a") or ""; local ok,why,code=p:close()
    return ok==true or code==0, trim(out~="" and out or (why or "command failed"))
end
local function quiet(cmd) local ok=os.execute(cmd .. " >/dev/null 2>&1"); return ok==true or ok==0 end
local function mkdirp(path) return (fs and fs.mkdirr and fs.mkdirr(path)) or quiet("mkdir -p " .. q(path)) end
local function read(path) local f=io.open(path,"r"); if not f then return nil end; local v=f:read("*a"); f:close(); return v end
local function write(path,value)
    mkdirp(RUNTIME); seq=seq+1; local s,u=nixio.gettimeofday(); local tmp=string.format("%s.tmp.%d.%d.%d.%d",path,nixio.getpid(),s,u or 0,seq)
    local f,e=io.open(tmp,"w"); if not f then return false,e end
    if not f:write(value) then f:close(); os.remove(tmp); return false,"cannot write temporary file" end
    if not f:close() then os.remove(tmp); return false,"cannot close temporary file" end
    quiet("chmod 600 " .. q(tmp)); if not os.rename(tmp,path) then os.remove(tmp); return false,"cannot replace "..path end; return true
end
local function num(v) if not v then return nil end; if v:match("^0[xX]") then return tonumber(v:sub(3),16) end; return tonumber(v) end

local function parse(raw)
    raw=tostring(raw or ""); if #raw>MAX then return nil,"routing file is larger than 32 KiB" end; if raw:find("%z") then return nil,"routing file contains a NUL byte" end
    raw=raw:gsub("\r\n","\n"):gsub("\r","\n")
    local routes,rules,lines={},{},{}
    for line in (raw.."\n"):gmatch("(.-)\n") do
        line=trim(line)
        if line~="" and line:sub(1,1)~="#" then
            local fam,prefix,tab=line:match("^ip%s+%-([46])%s+route%s+replace%s+local%s+(%S+)%s+dev%s+lo%s+table%s+(%d+)$")
            if fam then
                if routes[fam] then return nil,"duplicate IPv"..fam.." route" end
                routes[fam]={family=fam,prefix=prefix,table=tonumber(tab),route=line}; lines[#lines+1]=line
            else
                local mark,mask
                fam,mark,mask,tab=line:match("^ip%s+%-([46])%s+rule%s+add%s+fwmark%s+([^/%s]+)/([^%s]+)%s+lookup%s+(%d+)$")
                if not fam then return nil,"unsupported routing command: "..line end
                if rules[fam] then return nil,"duplicate IPv"..fam.." rule" end
                mark,mask=num(mark),num(mask); tab=tonumber(tab)
                if not mark or not mask or mark<1 or mask<1 or mark>4294967295 or mask>4294967295 then return nil,"invalid firewall mark or mask" end
                rules[fam]={family=fam,mark=mark,mask=mask,table=tab,rule=line}; lines[#lines+1]=line
            end
        end
    end
    if not routes["4"] or not rules["4"] then return nil,"routing file must declare IPv4 route and rule" end
    if (routes["6"] and not rules["6"]) or (rules["6"] and not routes["6"]) then return nil,"routing file must declare both IPv6 route and rule" end
    local s={normalized=table.concat(lines,"\n").."\n",commands=lines,route_commands={},rule_commands={},ipv6_enabled=routes["6"]~=nil}
    for _,fam in ipairs({"4","6"}) do if routes[fam] then
        if routes[fam].table~=rules[fam].table then return nil,"IPv"..fam.." route and rule must use the same table" end
        local spec={family=fam,prefix=routes[fam].prefix,table=routes[fam].table,mark=rules[fam].mark,mask=rules[fam].mask,route=routes[fam].route,rule=rules[fam].rule}
        s["ipv"..fam]=spec; s.route_commands[#s.route_commands+1]=spec.route; s.rule_commands[#s.rule_commands+1]=spec.rule
    end end
    s.mark,s.mask,s.table=s.ipv4.mark,s.ipv4.mask,s.ipv4.table; return s
end

local function rule_present(s)
    local ok,out=run("ip -"..s.family.." rule show"); if not ok then return false end
    for line in (out.."\n"):gmatch("(.-)\n") do
        local body=trim((line:gsub("^%s*%d+:%s*", "", 1)))
        local fw,tab=body:match("^from%s+all%s+fwmark%s+(%S+)%s+[Ll]ookup%s+(%S+)$")
        if fw and tab then
            local m,k=fw:match("^([^/]+)/(.+)$"); m=num(m or fw); k=num(k or "0xffffffff")
            if m==s.mark and k==s.mask and num(tab)==s.table then return true end
        end
    end
    return false
end
local function normalize_prefix(family,prefix)
    if prefix=="default" then return family=="4" and "0.0.0.0/0" or "::/0" end
    return prefix
end
local function route_state(s)
    local ok,out=run("ip -"..s.family.." route show table "..s.table); if not ok then return false,false end
    local exact,conflict=false,false
    local expected=normalize_prefix(s.family,s.prefix)
    for line in (out.."\n"):gmatch("(.-)\n") do
        line=trim(line); local kind,prefix=line:match("^(%S+)%s+(%S+)")
        if normalize_prefix(s.family,prefix)==expected then
            if kind=="local" and line:match("%sdev%s+lo") then exact=true else conflict=true end
        end
    end
    return exact,conflict
end
local function active(s) local r=route_state(s); return r==true and rule_present(s) end
local function same_route_spec(a,b) return a and b and a.family==b.family and normalize_prefix(a.family,a.prefix)==normalize_prefix(b.family,b.prefix) and a.table==b.table end
local function del_route(s) return quiet("ip -"..s.family.." route del local "..q(s.prefix).." dev lo table "..s.table) end
local function del_rules(s)
    local count=0
    while rule_present(s) do
        if count>=64 or not quiet("ip -"..s.family.." rule del fwmark "..s.mark.."/"..s.mask.." lookup "..s.table) then return false end
        count=count+1
    end
    return true
end
local function ensure_route(s)
    local exact,conflict=route_state(s)
    if conflict then return false,"refusing to replace existing IPv"..s.family.." route "..s.prefix end
    if not exact and not quiet("ip -"..s.family.." route add local "..q(s.prefix).." dev lo table "..s.table) then return false,"failed to add IPv"..s.family.." route" end
    if not route_state(s) then return false,"IPv"..s.family.." route verification failed" end
    return true
end
local function ensure_rule(s)
    if not rule_present(s) and not quiet(s.rule) then return false,"failed to add IPv"..s.family.." rule" end
    if not rule_present(s) then return false,"IPv"..s.family.." rule verification failed" end
    return true
end
local function remove_state(s,keep_routes)
    if not s then return true end
    for _,f in ipairs({"4","6"}) do local x=s["ipv"..f]
        if x and rule_present(x) and not del_rules(x) then return false,"failed to delete IPv"..f.." rule" end
    end
    for _,f in ipairs({"4","6"}) do local x=s["ipv"..f]; local keep=keep_routes and keep_routes["ipv"..f]
        if x and not same_route_spec(x,keep) then
            local exact=route_state(x)
            if exact and not del_route(x) then return false,"failed to delete IPv"..f.." route" end
        end
    end
    return true
end
local function install_state(s)
    for _,f in ipairs({"4","6"}) do local x=s["ipv"..f]; if x then local ok,e=ensure_route(x); if not ok then return false,e end end end
    for _,f in ipairs({"4","6"}) do local x=s["ipv"..f]; if x then local ok,e=ensure_rule(x); if not ok then return false,e end end end
    for _,f in ipairs({"4","6"}) do local x=s["ipv"..f]; if x and not active(x) then return false,"IPv"..f.." policy route verification failed" end end
    return true
end
local function rollback(previous,current)
    local errors={}
    local ok,e=remove_state(current,previous); if not ok then errors[#errors+1]=e end
    if previous then ok,e=install_state(previous); if not ok then errors[#errors+1]=e end end
    return #errors==0,table.concat(errors,"; ")
end

local function state(s)
    local v4=s and s.ipv4 and active(s.ipv4) or false; local v6=s and s.ipv6 and active(s.ipv6) or false
    return {active=v4 and (not s.ipv6_enabled or v6),ipv4=v4,ipv6=v6}
end
local function runtime_text(s)
    if not s then return "# No active policy routing commands are installed.\n" end
    local out={}; for _,f in ipairs({"4","6"}) do local x=s["ipv"..f]; if x then local _,r=run("ip -"..f.." rule show"); local _,t=run("ip -"..f.." route show table "..x.table); out[#out+1]="# ip -"..f.." rule show\n"..r; out[#out+1]="# ip -"..f.." route show table "..x.table.."\n"..t end end
    return table.concat(out,"\n\n").."\n"
end
local function validate(raw)
    local s,e=parse(raw); if not s then return {ok=false,valid=false,error=e} end
    return {ok=true,valid=true,config=s.normalized,bytes=#s.normalized,commands=s.commands,route_commands=s.route_commands,rule_commands=s.rule_commands,ipv6_enabled=s.ipv6_enabled,firewall_mark=s.mark,routing_table=s.table}
end
local function read_current()
    local raw=read(SOURCE); if not raw then return {ok=false,error="cannot read "..SOURCE,path=SOURCE} end; local s,e=parse(raw); if not s then return {ok=false,error=e,path=SOURCE} end
    local ar=read(APPLIED); local a=ar and parse(ar) or s; local st=state(a)
    return {ok=true,path=SOURCE,config=s.normalized,bytes=#s.normalized,commands=s.commands,route_commands=s.route_commands,rule_commands=s.rule_commands,active=runtime_text(a),route_active=st.active,route_ipv4=st.ipv4,route_ipv6=st.ipv6,ipv6_enabled=s.ipv6_enabled,firewall_mark=s.mark,routing_table=s.table,applied_config=ar or "",applied_path=APPLIED,candidate_path=CANDIDATE}
end
local function save(raw) local s,e=parse(raw); if not s then return {ok=false,valid=false,error=e} end; local ok,err=write(SOURCE,s.normalized); return ok and {ok=true,valid=true,path=SOURCE,config=s.normalized,bytes=#s.normalized} or {ok=false,valid=true,error=err} end
local function apply(raw,candidate)
    local s,e=parse(raw); if not s then return {ok=false,valid=false,error=e} end
    if candidate then local ok,err=write(CANDIDATE,s.normalized); if not ok then return {ok=false,error=err} end end
    local pr=read(APPLIED); local previous=nil
    if pr then previous,e=parse(pr); if not previous then return {ok=false,error="invalid applied routing state: "..tostring(e)} end end
    local changed=previous and previous.normalized~=s.normalized
    if changed then
        local ok,err=remove_state(previous,s)
        if not ok then
            local rok,re=install_state(previous); if not rok then err=err.."; rollback failed: "..re end
            return {ok=false,error=err}
        end
    end
    local ok,err=install_state(s)
    if not ok then
        local rok,re=rollback(previous,s); if not rok then err=err.."; rollback failed: "..re end
        return {ok=false,error=err}
    end
    ok,err=write(APPLIED,s.normalized)
    if not ok then
        local rok,re=rollback(previous,s); if not rok then err=err.."; rollback failed: "..re end
        return {ok=false,error=err}
    end
    os.remove(LEGACY_OWNERSHIP)
    local st=state(s); return {ok=true,valid=true,applied=true,config=s.normalized,applied_config=s.normalized,routing_active=runtime_text(s),route_active=st.active,route_ipv4=st.ipv4,route_ipv6=st.ipv6,ipv6_enabled=s.ipv6_enabled,policy_route_commands=s.commands,route_commands=s.route_commands,rule_commands=s.rule_commands,firewall_mark=s.mark,routing_table=s.table}
end
local function remove()
    local raw=read(APPLIED) or read(SOURCE)
    if not raw then os.remove(CANDIDATE); os.remove(LEGACY_OWNERSHIP); return {ok=true,route_active=false} end
    local s,e=parse(raw); if not s then return {ok=false,error=e} end
    local ok,err=remove_state(s,nil); if not ok then return {ok=false,error=err} end
    os.remove(APPLIED); os.remove(CANDIDATE); os.remove(LEGACY_OWNERSHIP); return {ok=true,route_active=false}
end
local function payload(path) if not tostring(path or ""):match("^/var/run/nftflow/rpc%-[A-Za-z0-9]+/payload$") then return nil,"invalid internal RPC input path" end; local v=read(path); return v,v and nil or "cannot read internal RPC input file" end

local cmd=arg[1] or ""; local result
if cmd=="routing-read" then result=read_current()
elseif cmd=="routing-validate" then result=validate(arg[2])
elseif cmd=="routing-save" then result=save(arg[2])
elseif cmd=="routing-apply" then result=apply(arg[2],true)
elseif cmd=="routing-validate-file" or cmd=="routing-save-file" or cmd=="routing-apply-file" then local raw,e=payload(arg[2]); if not raw then result={ok=false,error=e} elseif cmd=="routing-validate-file" then result=validate(raw) elseif cmd=="routing-save-file" then result=save(raw) else result=apply(raw,true) end
elseif cmd=="route-apply" or (cmd=="route" and (arg[2] or "add")=="add") then local raw=read(SOURCE); result=raw and apply(raw,false) or {ok=false,error="cannot read "..SOURCE}
elseif cmd=="route" and arg[2]=="del" then result=remove()
elseif cmd=="status" then local raw=read(APPLIED) or read(SOURCE); local s=raw and parse(raw) or nil; local st=state(s); result={ok=true,active=st.active,ipv4=st.ipv4,ipv6=st.ipv6,text=runtime_text(s)}
else result={ok=false,error="unsupported routing command"} end
io.write(encode(result).."\n"); os.exit(result.ok==false and 1 or 0)
