#!/usr/bin/lua
-- SPDX-License-Identifier: Apache-2.0
--
-- The Xray core configuration is deliberately just one hand-written JSON
-- file. UCI contains the OpenWrt-side process/runtime settings; Firewall and
-- Routing are independent expert-managed files.

local jsonc = require "luci.jsonc"
local nixio = require "nixio"
local nixio_fs = require "nixio.fs"

local UCLIENT_FETCH = "/bin/uclient-fetch"
local RUNTIME = "/var/run/nftflow"
local DEFAULT_CONFIG = "/etc/nftflow/config.json"
local FIREWALL_SOURCE = "/etc/nftflow/firewall.nft"
local ROUTING_SOURCE = "/etc/nftflow/routing.conf"
local RUNTIME_FIREWALL_CANDIDATE = RUNTIME .. "/firewall.candidate.nft"
local RUNTIME_FIREWALL_APPLIED = RUNTIME .. "/firewall.applied.nft"
local RUNTIME_ROUTING_CANDIDATE = RUNTIME .. "/routing.candidate.conf"
local RUNTIME_ROUTING_APPLIED = RUNTIME .. "/routing.applied.conf"
local PID_FILE = RUNTIME .. "/xray.pid"
local STATE_FILE = RUNTIME .. "/state.json"
local EDITOR_MAX_BYTES = 32 * 1024
local DEFAULT_FIREWALL_MARK = 1
local DEFAULT_ROUTING_TABLE = 100
local DEFAULT_RUN_GID = 23333
local CONNECTIVITY_TARGETS = {
    baidu = { label = "Baidu", url = "https://www.baidu.com" },
    google = { label = "Google", url = "https://www.google.com/generate_204" }
}
local DEFAULT_GEOIP_URL = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
local DEFAULT_GEBSITE_URL = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
local GEO_UPDATE_STATE = RUNTIME .. "/geo-update.json"
local GEO_KINDS = { "geoip", "geosite" }
local GEO_AUTO_UPDATE_INTERVAL = 30 * 24 * 60 * 60
local GEO_AUTO_UPDATE_TAG = "nftflow-geodata-monthly"
local GEO_UPDATE_START_TIMEOUT = 120
local NFTFLOW_TABLE = "nftflow"
local temporary_sequence = 0
local process_pid
local remove_geo_update_lock
local terminate_pid
local geo_update_active
local geo_update_state_expired
local route_spec_active
local nft_transaction_content
local canonical_path

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

local function exec_capture(command)
    local pipe = io.popen(command .. " 2>&1")
    if not pipe then return false, "unable to execute command" end
    local output = pipe:read("*a") or ""
    local ok, reason, code = pipe:close()
    if ok == true or code == 0 then return true, output end
    return false, trim(output ~= "" and output or (reason or "command failed"))
end

local function exec_quiet(command)
    local ok = os.execute(command .. " >/dev/null 2>&1")
    return ok == true or ok == 0
end

local function log_event(message)
    exec_quiet("logger -t nftflowctl " .. shellquote(message))
end

local function uclient_fetch_available()
    return exec_quiet("[ -x " .. shellquote(UCLIENT_FETCH) .. " ]")
end

local function mkdirp(path)
    if nixio_fs and nixio_fs.mkdirr then return nixio_fs.mkdirr(path) end
    return exec_quiet("mkdir -p " .. shellquote(path))
end

local function dirname(path)
    return tostring(path):match("^(.*)/[^/]*$") or "."
end

local function read_file(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local value = file:read("*a")
    file:close()
    return value
end

local function temporary_path(path)
    temporary_sequence = temporary_sequence + 1
    local seconds, microseconds = nixio.gettimeofday()
    return string.format("%s.tmp.%d.%d.%d.%d", path, nixio.getpid(), seconds, microseconds or 0, temporary_sequence)
end

local function write_atomic(path, value, mode)
    if not mkdirp(dirname(path)) then return false, "cannot create " .. dirname(path) end
    local temporary = temporary_path(path)
    local file, err = io.open(temporary, "w")
    if not file then return false, err or "cannot open temporary file" end
    local written = file:write(value)
    if not written then
        file:close()
        os.remove(temporary)
        return false, "cannot write temporary file"
    end
    local closed, close_error = file:close()
    if not closed then
        os.remove(temporary)
        return false, close_error or "cannot close temporary file"
    end
    if mode then exec_quiet("chmod " .. tostring(mode) .. " " .. shellquote(temporary)) end
    if not os.rename(temporary, path) then
        os.remove(temporary)
        return false, "cannot replace " .. path
    end
    if mode then exec_quiet("chmod " .. tostring(mode) .. " " .. shellquote(path)) end
    return true
end

local function read_runtime_state()
    local raw = read_file(STATE_FILE)
    if not raw then return nil end
    local ok, state = pcall(json_decode, raw)
    if not ok or type(state) ~= "table" then return nil end
    return state
end

local RUNTIME_STATES = {
    starting = true,
    ready = true,
    stopping = true,
    stopped = true,
    failed = true
}

local function write_runtime_state(state, pid, message)
    if not RUNTIME_STATES[state] then return nil, "invalid runtime state: " .. tostring(state) end
    if pid ~= nil and trim(pid) == "" then pid = nil end
    if pid ~= nil then
        pid = tonumber(pid)
        if not pid or pid < 2 or pid % 1 ~= 0 then return nil, "invalid runtime PID" end
    end
    if not mkdirp(RUNTIME) then return nil, "cannot create " .. RUNTIME end
    local previous = read_runtime_state() or {}
    local now = os.time()
    local result = {
        state = state,
        updated = now,
        restart_count = tonumber(previous.restart_count) or 0
    }
    if state == "starting" then
        result.pid = pid
        result.started = now
        if previous.state == "failed" or previous.state == "ready" or previous.state == "starting" then
            result.restart_count = result.restart_count + 1
        end
    elseif state == "ready" or state == "stopping" then
        result.pid = pid or tonumber(previous.pid)
        result.started = tonumber(previous.started)
    elseif state == "failed" then
        result.pid = pid
        result.started = tonumber(previous.started)
        result.finished = now
    elseif state == "stopped" then
        result.finished = now
    end
    if message and tostring(message) ~= "" then result.error = tostring(message) end
    if (state == "starting" or state == "ready" or state == "stopping") and result.pid then
        local saved_pid, pid_error = write_atomic(PID_FILE, tostring(result.pid) .. "\n", 600)
        if not saved_pid then return nil, pid_error end
    else
        os.remove(PID_FILE)
    end
    local saved, save_error = write_atomic(STATE_FILE, json_encode(result) .. "\n", 600)
    if not saved then
        if state == "starting" or state == "ready" or state == "stopping" then os.remove(PID_FILE) end
        return nil, save_error
    end
    local event = "guarded runner state: " .. state
    if result.pid then event = event .. " pid=" .. tostring(result.pid) end
    if message and tostring(message) ~= "" then event = event .. " - " .. tostring(message) end
    log_event(event)
    return result
end

local function runtime_process_alive()
    local pid = tonumber(trim(read_file(PID_FILE)))
    if not pid or pid < 2 or pid % 1 ~= 0 then return false end
    local configured_ok, configured = exec_capture("/sbin/uci -q get nftflow.main.xray_bin")
    local expected = "/usr/bin/xray"
    if configured_ok and trim(configured) ~= "" then expected = trim(configured) end
    local expected_path = canonical_path(expected)
    local actual_ok, actual_path = exec_capture("readlink -f /proc/" .. tostring(pid) .. "/exe")
    return exec_quiet("kill -0 " .. tostring(pid)) and actual_ok and
        trim(actual_path) == trim(expected_path)
end

local function remove_runtime_temporary_files()
    if runtime_process_alive() then return end

    for _, pattern in ipairs({
        RUNTIME .. "/firewall-check*.nft*",
        RUNTIME .. "/firewall-apply*.nft*",
        RUNTIME .. "/config-check*.json*",
        RUNTIME .. "/*.nftflow-result.*",
        RUNTIME .. "/*.nftflow-download.*",
        RUNTIME .. "/*.tmp.*"
    }) do
        exec_quiet("rm -f " .. pattern)
    end

    os.remove(PID_FILE)
    local state = read_runtime_state()
    if not state then
        os.remove(STATE_FILE)
    elseif state.state == "starting" or state.state == "ready" or state.state == "stopping" then
        local failed = write_runtime_state("failed", nil, "stale runtime state cleaned during prepare")
        if not failed then os.remove(STATE_FILE) end
    elseif not RUNTIME_STATES[state.state] then
        os.remove(STATE_FILE)
    end
end

local function cleanup_all_rpc_temporary_dirs()
    local command = "if [ -d " .. shellquote(RUNTIME) .. " ]; then find " .. shellquote(RUNTIME) ..
        " -maxdepth 1 -type d -name 'rpc-*' -exec rm -rf {} \\; fi"
    if not exec_quiet(command) then return false, "cannot clean RPC temporary directories" end
    return true
end

local function uci_get(option, default)
    local ok, output = exec_capture("/sbin/uci -q get nftflow.main." .. option)
    output = trim(output)
    return ok and output ~= "" and output or default
end

local function service_sync()
    local enabled = trim(uci_get("enabled", "0"))
    local command = enabled == "1" and "enable" or "disable"
    local expected = enabled == "1"
    local ok, output = exec_capture("/etc/init.d/nftflow " .. command)
    if not ok then
        return {
            ok = false,
            enabled = expected,
            action = command,
            error = trim(output ~= "" and output or "unable to synchronize service boot state")
        }
    end

    local verified, verification_output = exec_capture("/etc/init.d/nftflow enabled")
    if verified ~= expected then
        return {
            ok = false,
            enabled = expected,
            action = command,
            error = trim(verification_output ~= "" and verification_output or
                "service boot state did not match nftflow.main.enabled")
        }
    end
    return { ok = true, enabled = expected, action = command }
end

local function configured_gid()
    local gid = tonumber(uci_get("run_gid", tostring(DEFAULT_RUN_GID)))
    if not gid or gid < 1 or gid > 65535 or gid % 1 ~= 0 then
        error("run_gid must be between 1 and 65535")
    end
    return gid
end

local function bool(value, default)
    if value == nil then return default == true end
    return value == true or value == 1 or value == "1" or value == "true" or value == "yes" or value == "on"
end

local function nonempty(value)
    value = trim(value)
    return value ~= "" and value or nil
end

local function build_main()
    local main = {
        enabled = bool(uci_get("enabled", "0"), false),
        mode = uci_get("mode", "tproxy"),
        xray_bin = uci_get("xray_bin", "/usr/bin/xray"),
        config_file = uci_get("config_file", DEFAULT_CONFIG),
        asset_dir = uci_get("asset_dir", "/usr/share/xray"),
        run_gid = configured_gid(),
        run_group = uci_get("run_group", "nftflow"),
        nofile = tonumber(uci_get("nofile", "65536")) or 65536,
        error_log = uci_get("error_log", "/var/log/nftflow/error.log")
    }
    if main.mode ~= "tproxy" then error("only tproxy mode is supported") end
    if main.run_gid < 1 or main.run_gid > 65535 then error("run_gid must be between 1 and 65535") end
    if main.nofile < 1024 then error("nofile must be at least 1024") end
    return main
end

local function parse_document(raw, path)
    if not raw then return nil, "cannot read " .. path end
    local ok, value = pcall(json_decode, raw)
    if not ok or type(value) ~= "table" then return nil, "invalid JSON in " .. path end
    local has_number = false
    for key in pairs(value) do
        if type(key) ~= "string" then has_number = true end
    end
    if has_number or trim(raw):sub(1, 1) ~= "{" then return nil, "JSON document root must be an object" end
    return value
end

local function load_config(path)
    local raw = read_file(path)
    local value, err = parse_document(raw, path)
    if not value then return nil, nil, err end
    return value, raw
end

local function config_read()
    local ok, main = pcall(build_main)
    if not ok then return { ok = false, error = main } end
    local raw = read_file(main.config_file)
    if not raw then return { ok = false, error = "cannot read " .. main.config_file, path = main.config_file } end
    local _, err = parse_document(raw, main.config_file)
    return {
        ok = true,
        config = raw,
        path = main.config_file,
        bytes = #raw,
        syntax = err == nil,
        error = err
    }
end

local function config_save(raw)
    local ok, main = pcall(build_main)
    if not ok then return { ok = false, error = main } end
    raw = tostring(raw or "")
    if #raw > EDITOR_MAX_BYTES then return { ok = false, error = "configuration is larger than 32 KiB" } end
    local _, err = parse_document(raw, main.config_file)
    if err then return { ok = false, syntax = false, error = err } end
    local saved, save_error = write_atomic(main.config_file, raw:gsub("\r\n", "\n") .. (raw:sub(-1) == "\n" and "" or "\n"), 600)
    if not saved then return { ok = false, error = save_error } end
    return { ok = true, path = main.config_file, bytes = #raw }
end

local function read_rpc_input(path)
    path = tostring(path or "")
    if not path:match("^/var/run/nftflow/rpc%-[A-Za-z0-9]+/payload$") then
        return nil, "invalid internal RPC input path"
    end
    local raw = read_file(path)
    if raw == nil then return nil, "cannot read internal RPC input file" end
    return raw
end

local function config_save_file(path)
    local raw, read_error = read_rpc_input(path)
    if raw == nil then return { ok = false, error = read_error } end
    return config_save(raw)
end

local function strip_nft_comments_and_strings(raw)
    raw = tostring(raw or "")
    local output = {}
    local quoted = false
    local escaped = false
    local comment = false
    for index = 1, #raw do
        local character = raw:sub(index, index)
        if comment then
            if character == "\n" then
                comment = false
                output[#output + 1] = character
            else
                output[#output + 1] = " "
            end
        elseif quoted then
            output[#output + 1] = character == "\n" and character or " "
            if escaped then
                escaped = false
            elseif character == "\\" then
                escaped = true
            elseif character == '"' then
                quoted = false
            end
        elseif character == "#" then
            comment = true
            output[#output + 1] = " "
        elseif character == '"' then
            quoted = true
            output[#output + 1] = " "
        else
            output[#output + 1] = character
        end
    end
    return table.concat(output)
end

local function parse_firewall_document(raw)
    local text = strip_nft_comments_and_strings(raw)
    local tables = {}
    local position = 1

    local function skip_whitespace(value)
        while value <= #text and text:sub(value, value):match("%s") do
            value = value + 1
        end
        return value
    end

    while true do
        position = skip_whitespace(position)
        if position > #text then return tables end

        local start, finish, family, name = text:find(
            "%f[%a]table%f[%A]%s+([%a%d]+)%s+([%a_][%w_.%-]*)%s*{", position)
        if start ~= position then
            return nil, "unsupported top-level nft statement"
        end

        local depth = 1
        local block_position = finish + 1
        while block_position <= #text and depth > 0 do
            local character = text:sub(block_position, block_position)
            if character == "{" then
                depth = depth + 1
            elseif character == "}" then
                depth = depth - 1
            end
            block_position = block_position + 1
        end
        if depth ~= 0 then return nil, "unbalanced nft table block" end

        tables[#tables + 1] = { family = family, name = name, key = family .. " " .. name }
        position = block_position
    end
end

local function extract_firewall_tables(raw)
    local tables = parse_firewall_document(raw)
    return tables or {}
end

local function nft_has_token(text, token)
    text = tostring(text or "")
    token = tostring(token or "")
    if text == token then return true end
    return text:match("^" .. token .. "[^%w_%-]") ~= nil or
        text:match("[^%w_%-]" .. token .. "[^%w_%-]") ~= nil or
        text:match("[^%w_%-]" .. token .. "$") ~= nil
end

local function normalize_firewall(raw)
    raw = tostring(raw or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if raw ~= "" and raw:sub(-1) ~= "\n" then raw = raw .. "\n" end
    return raw, extract_firewall_tables(raw)
end

local function nft_number(value)
    value = trim(value)
    if value:match("^0[xX][%da-fA-F]+$") then return tonumber(value:sub(3), 16) end
    return tonumber(value)
end

local function canonical_route_prefix(family, prefix)
    if prefix == "default" then
        return family == "4" and "0.0.0.0/0" or "::/0"
    end
    return prefix
end

local function policy_rule_mark(value)
    value = trim(value)
    local mark_literal, mask_literal = value:match("^([^/]+)/(.+)$")
    local mark = nft_number(mark_literal or value)
    local mask = nft_number(mask_literal or "0xffffffff")
    return mark, mask
end

local function firewall_scope_error(raw)
    if nft_has_token(strip_nft_comments_and_strings(raw), "include") then
        return "firewall file must not use include directives"
    end
    local tables, document_error = parse_firewall_document(raw)
    if document_error then return document_error end
    for _, table_spec in ipairs(tables) do
        if table_spec.name ~= NFTFLOW_TABLE then
            return "firewall file may only manage tables named nftflow"
        end
    end
    return nil
end

local function routing_settings(raw)
    raw = tostring(raw or "")
    if #raw > EDITOR_MAX_BYTES then return nil, "routing file is larger than 32 KiB" end
    if raw:find("%z") then return nil, "routing file contains a NUL byte" end

    local commands = {}
    local route_commands = {}
    local rule_commands = {}
    local routes = {}
    local rules = {}
    for line in (raw .. "\n"):gmatch("(.-)\n") do
        local value = trim(line)
        if value ~= "" and value:sub(1, 1) ~= "#" then
            local family, prefix, table_id = value:match("^ip%s+%-([46])%s+route%s+replace%s+local%s+(%S+)%s+dev%s+lo%s+table%s+(%d+)$")
            if family then
                if routes[family] then return nil, "routing file declares more than one ip -" .. family .. " route command" end
                local table_number = tonumber(table_id)
                if not table_number or table_number < 1 or table_number > 4294967295 then
                    return nil, "routing table is outside 1..4294967295"
                end
                if family == "4" and not prefix:match("^%d+%.%d+%.%d+%.%d+/%d+$") then
                    return nil, "invalid IPv4 local route prefix"
                elseif family == "6" and not prefix:match("^[0-9A-Fa-f:]+/%d+$") then
                    return nil, "invalid IPv6 local route prefix"
                end
                routes[family] = { command = value, prefix = prefix, table = table_number }
                route_commands[#route_commands + 1] = value
                commands[#commands + 1] = value
            else
                family, local_mark, mask, table_id = value:match("^ip%s+%-([46])%s+rule%s+add%s+fwmark%s+(%d+)/(%d+)%s+lookup%s+(%d+)$")
                if not family then return nil, "unsupported routing command: " .. value end
                if rules[family] then return nil, "routing file declares more than one ip -" .. family .. " rule command" end
                local mark_number, mask_number, table_number = tonumber(local_mark), tonumber(mask), tonumber(table_id)
                if not mark_number or not mask_number or mark_number < 1 or mask_number < 1 or
                    mark_number > 4294967295 or mask_number > 4294967295 then
                    return nil, "firewall mark or mask is outside 1..4294967295"
                end
                if not table_number or table_number < 1 or table_number > 4294967295 then
                    return nil, "routing table is outside 1..4294967295"
                end
                rules[family] = { command = value, mark = mark_number, mask = mask_number, table = table_number }
                rule_commands[#rule_commands + 1] = value
                commands[#commands + 1] = value
            end
        end
    end

    if not routes["4"] or not rules["4"] then return nil, "routing file must declare both IPv4 route and rule commands" end
    if (routes["6"] and not rules["6"]) or (rules["6"] and not routes["6"]) then
        return nil, "routing file must declare both IPv6 route and rule commands"
    end
    local function make_family(family)
        local route, rule = routes[family], rules[family]
        if not route then return nil end
        if route.table ~= rule.table then return nil, "IPv" .. family .. " route and rule must use the same table" end
        return {
            family = family,
            route = route.command,
            rule = rule.command,
            prefix = route.prefix,
            mark = rule.mark,
            mask = rule.mask,
            table = rule.table
        }
    end
    local ipv4, ipv4_error = make_family("4")
    if not ipv4 then return nil, ipv4_error end
    local ipv6, ipv6_error = make_family("6")
    if routes["6"] and not ipv6 then return nil, ipv6_error end
    return {
        raw = raw,
        normalized = #commands > 0 and table.concat(commands, "\n") .. "\n" or "",
        commands = commands,
        route_commands = route_commands,
        rule_commands = rule_commands,
        ipv4 = ipv4,
        ipv6 = ipv6,
        ipv6_enabled = ipv6 ~= nil,
        mark = ipv4.mark,
        mask = ipv4.mask,
        table = ipv4.table
    }
end


local function table_command(verb, spec)
    return verb .. " table " .. spec.family .. " " .. spec.name
end

local function table_active(spec)
    return exec_quiet(table_command("nft list", spec))
end

local function managed_firewall_tables()
    local tables = {}
    local seen = {}
    local listed, output = exec_capture("nft list tables")
    if not listed then return tables end
    for line in (output .. "\n"):gmatch("(.-)\n") do
        local family, name = trim(line):match("^table%s+(%S+)%s+(%S+)$")
        local key = family and name and family .. " " .. name or nil
        if name == NFTFLOW_TABLE and not seen[key] then
            seen[key] = true
            tables[#tables + 1] = { family = family, name = name, key = key }
        end
    end
    return tables
end

local function active_firewall(tables)
    tables = tables or managed_firewall_tables()
    local output, missing = {}, {}
    for _, spec in ipairs(tables) do
        local ok, listed = exec_capture(table_command("nft list", spec))
        if ok and trim(listed) ~= "" then
            output[#output + 1] = trim(listed)
        else
            missing[#missing + 1] = spec.key
        end
    end
    local active = #output > 0 and table.concat(output, "\n") .. "\n" or
        "# No managed NftFlow nftables tables were found.\n"
    if #tables == 0 then
        return active, false, {}, 0
    end
    if #missing > 0 then
        return active, false, missing, #output
    end
    return active, true, {}, #output
end

local function route_status(settings)
    if not settings or not settings.ipv4 then
        return { active = false, ipv4 = false, ipv6 = false }
    end
    local function family_active(family)
        local spec = settings["ipv" .. family]
        if not spec then return true end
        return route_spec_active(spec)
    end
    local v4 = family_active("4")
    local v6 = family_active("6")
    return { active = v4 and v6, ipv4 = v4, ipv6 = settings.ipv6_enabled and v6 or false }
end

local function active_routing(settings)
    if not settings then return "# No valid policy routing configuration is available.\n" end
    local output = {}
    local function capture(label, command)
        local ok, value = exec_capture(command)
        value = trim(value)
        if ok and value ~= "" then
            output[#output + 1] = "# " .. label .. "\n" .. value
        elseif not ok then
            output[#output + 1] = "# " .. label .. " unavailable: " .. (value ~= "" and value or "command failed")
        else
            output[#output + 1] = "# " .. label .. "\n(no entries)"
        end
    end
    for _, family in ipairs({ "4", "6" }) do
        local spec = settings["ipv" .. family]
        if spec then
            capture("ip -" .. family .. " rule show", "ip -" .. family .. " rule show")
            capture("ip -" .. family .. " route show table " .. tostring(spec.table),
                "ip -" .. family .. " route show table " .. tostring(spec.table))
        end
    end
    if #output == 0 then return "# No policy routing commands are configured.\n" end
    return table.concat(output, "\n\n") .. "\n"
end

local function policy_route_commands(settings)
    return settings and settings.commands or {}
end

local function parse_routing_file(path)
    local raw = read_file(path)
    if not raw then return nil, nil, "cannot read " .. path end
    local settings, routing_error = routing_settings(raw)
    if not settings then return nil, raw, routing_error end
    return settings, raw
end

local function read_applied_firewall()
    local raw = read_file(RUNTIME_FIREWALL_APPLIED)
    if raw == nil then return nil end
    return { normalized = raw }
end

local applied_routing

local function read_applied_routing()
    local settings = parse_routing_file(RUNTIME_ROUTING_APPLIED)
    if settings then return settings end
    return applied_routing and applied_routing() or nil
end

local function routing_result(settings, applied_raw)
    local applied = applied_raw and routing_settings(applied_raw) or nil
    local runtime = applied and route_status(applied) or { active = false, ipv4 = false, ipv6 = false }
    local active = applied and active_routing(applied) or "# No active policy routing commands are installed.\n"
    return {
        ok = true,
        path = ROUTING_SOURCE,
        config = settings.normalized,
        bytes = #settings.normalized,
        commands = settings.commands,
        route_commands = settings.route_commands,
        rule_commands = settings.rule_commands,
        active = active,
        route_active = runtime.active,
        route_ipv4 = runtime.ipv4,
        route_ipv6 = runtime.ipv6,
        ipv6_enabled = settings.ipv6_enabled,
        firewall_mark = settings.mark,
        routing_table = settings.table,
        applied_config = applied and applied.normalized or "",
        applied_path = RUNTIME_ROUTING_APPLIED,
        candidate_path = RUNTIME_ROUTING_CANDIDATE
    }
end

local function routing_read()
    local settings, _, routing_error = parse_routing_file(ROUTING_SOURCE)
    if not settings then return { ok = false, error = routing_error, path = ROUTING_SOURCE } end
    return routing_result(settings, read_file(RUNTIME_ROUTING_APPLIED))
end

local function routing_validate(raw)
    local settings, routing_error = routing_settings(raw)
    if not settings then return { ok = false, valid = false, error = routing_error } end
    return {
        ok = true,
        valid = true,
        config = settings.normalized,
        bytes = #settings.normalized,
        commands = settings.commands,
        route_commands = settings.route_commands,
        rule_commands = settings.rule_commands,
        ipv6_enabled = settings.ipv6_enabled,
        firewall_mark = settings.mark,
        routing_table = settings.table
    }
end

local function routing_save(raw)
    local checked = routing_validate(raw)
    if not checked.valid then return checked end
    local saved, save_error = write_atomic(ROUTING_SOURCE, checked.config, 600)
    if not saved then return { ok = false, error = save_error } end
    return { ok = true, valid = true, path = ROUTING_SOURCE, config = checked.config, bytes = #checked.config }
end

local function firewall_validate(raw)
    raw = tostring(raw or "")
    if #raw > EDITOR_MAX_BYTES then return { ok = false, valid = false, error = "firewall file is larger than 32 KiB" } end
    if raw:find("%z") then return { ok = false, valid = false, error = "firewall file contains a NUL byte" } end
    local normalized, tables = normalize_firewall(raw)
    local scope_error = firewall_scope_error(normalized)
    if scope_error then return { ok = false, valid = false, error = scope_error } end
    if not mkdirp(RUNTIME) then return { ok = false, valid = false, error = "cannot create " .. RUNTIME } end
    local check_path = temporary_path(RUNTIME .. "/firewall-check.nft")
    local saved, save_error = write_atomic(check_path, normalized, 600)
    if not saved then return { ok = false, valid = false, error = save_error } end
    local pipe = io.popen("nft --check --file " .. shellquote(check_path) .. " 2>&1; printf '\\n__NFTFLOW_NFT_RC__%s\\n' \"$?\"")
    local detail = pipe and (pipe:read("*a") or "") or "unable to execute nft"
    if pipe then pipe:close() end
    local exit_code = tonumber(detail:match("__NFTFLOW_NFT_RC__(%d+)"))
    detail = detail:gsub("\n?__NFTFLOW_NFT_RC__%d+%s*$", "")
    local valid = exit_code == 0
    os.remove(check_path)
    local result = {
        ok = valid,
        valid = valid,
        detail = trim(detail),
        config = normalized,
        bytes = #normalized,
        tables = tables
    }
    if not valid then result.error = "nftables syntax check failed" end
    return result
end

local function firewall_read()
    local saved_raw = read_file(FIREWALL_SOURCE)
    if saved_raw == nil then return { ok = false, error = "cannot read " .. FIREWALL_SOURCE, path = FIREWALL_SOURCE } end
    local applied = read_applied_firewall()
    local candidate = read_file(RUNTIME_FIREWALL_CANDIDATE)
    local runtime_tables = managed_firewall_tables()
    local active, active_found, missing, active_count = active_firewall(runtime_tables)
    return {
        ok = true,
        config = saved_raw,
        path = FIREWALL_SOURCE,
        bytes = #saved_raw,
        active = active,
        active_found = active_found,
        missing_tables = missing,
        table_count = #runtime_tables,
        active_table_count = active_count,
        applied = applied ~= nil,
        applied_config = applied and applied.normalized or "",
        candidate_config = candidate or "",
        applied_path = RUNTIME_FIREWALL_APPLIED,
        candidate_path = RUNTIME_FIREWALL_CANDIDATE
    }
end

local function firewall_save(raw)
    local checked = firewall_validate(raw)
    if not checked.valid then return checked end
    local saved, save_error = write_atomic(FIREWALL_SOURCE, checked.config, 600)
    if not saved then return { ok = false, error = save_error } end
    return { ok = true, valid = true, path = FIREWALL_SOURCE, config = checked.config, bytes = #checked.config }
end

local function firewall_validate_file(path)
    local raw, read_error = read_rpc_input(path)
    if raw == nil then return { ok = false, valid = false, error = read_error } end
    return firewall_validate(raw)
end

local function firewall_save_file(path)
    local raw, read_error = read_rpc_input(path)
    if raw == nil then return { ok = false, error = read_error } end
    return firewall_save(raw)
end

local route_mode

local function policy_rule_delete_command(spec)
    return "ip -" .. spec.family .. " rule del fwmark " .. tostring(spec.mark) .. "/" .. tostring(spec.mask) .. " lookup " .. tostring(spec.table)
end

local function policy_route_add_command(spec)
    return "ip -" .. spec.family .. " route add local " .. tostring(spec.prefix) .. " dev lo table " .. tostring(spec.table)
end

local function policy_route_delete_command(spec)
    return "ip -" .. spec.family .. " route del local " .. tostring(spec.prefix) .. " dev lo table " .. tostring(spec.table)
end

local function policy_rule_entries(family)
    local ok, output = exec_capture("ip -" .. family .. " rule show")
    if not ok then return nil, "cannot inspect IPv" .. family .. " policy rules: " .. trim(output) end
    local entries = {}
    for line in (output .. "\n"):gmatch("(.-)\n") do
        local fwmark_literal = line:match("%f[%a]fwmark%s+([^%s]+)")
        local table_literal = line:match("%f[%a]lookup%s+([0-9A-Fa-fxX]+)")
        local mark, mask = policy_rule_mark(fwmark_literal)
        local table_id = nft_number(table_literal)
        if mark and mask and table_id then
            entries[#entries + 1] = { mark = mark, mask = mask, table = table_id, line = trim(line) }
        end
    end
    return entries
end

local function policy_route_entries(family, table_id)
    local ok, output = exec_capture("ip -" .. family .. " route show table " .. tostring(table_id))
    if not ok then return nil, "cannot inspect IPv" .. family .. " route table " .. tostring(table_id) .. ": " .. trim(output) end
    local entries = {}
    for line in (output .. "\n"):gmatch("(.-)\n") do
        local value = trim(line)
        local kind, prefix = value:match("^(%S+)%s+(%S+)")
        if kind and prefix then
            entries[#entries + 1] = {
                kind = kind,
                prefix = canonical_route_prefix(family, prefix),
                device = value:match("%sdev%s+(%S+)"),
                line = value
            }
        end
    end
    return entries
end

local function policy_rule_matches(entry, spec)
    return entry and spec and entry.mark == spec.mark and entry.mask == spec.mask and entry.table == spec.table
end

local function policy_route_matches(entry, spec)
    return entry and spec and entry.kind == "local" and
        entry.prefix == canonical_route_prefix(spec.family, spec.prefix) and entry.device == "lo"
end

local function policy_rule_present(spec, entries)
    entries = entries or policy_rule_entries(spec.family)
    if not entries then return false end
    for _, entry in ipairs(entries) do
        if policy_rule_matches(entry, spec) then return true end
    end
    return false
end

local function policy_route_present(spec, entries)
    entries = entries or policy_route_entries(spec.family, spec.table)
    if not entries then return false end
    for _, entry in ipairs(entries) do
        if policy_route_matches(entry, spec) then return true end
    end
    return false
end

local function clear_policy_rules(family, mark, mask, table_id)
    local spec = { family = family, mark = tonumber(mark), mask = tonumber(mask) or tonumber(mark), table = tonumber(table_id) }
    local entries, read_error = policy_rule_entries(family)
    if not entries then return false, read_error end
    for _, entry in ipairs(entries) do
        if policy_rule_matches(entry, spec) then
            if not exec_quiet(policy_rule_delete_command(spec)) then
                return false, "failed to delete NftFlow IPv" .. family .. " fwmark rule"
            end
            return true
        end
    end
    return true
end

applied_routing = function()
    local runtime_raw = read_file(RUNTIME_ROUTING_APPLIED)
    if runtime_raw then
        local runtime_settings = routing_settings(runtime_raw)
        if runtime_settings then return runtime_settings end
    end
    return nil
end

local function routing_ownership_for(settings, value, default)
    local ownership = {}
    for _, family in ipairs({ "4", "6" }) do
        local spec = settings and settings["ipv" .. family]
        if spec then
            local configured = value and value["ipv" .. family]
            local route_owned = default == true
            local rule_owned = default == true
            if configured and configured.route ~= nil then route_owned = configured.route == true end
            if configured and configured.rule ~= nil then rule_owned = configured.rule == true end
            ownership["ipv" .. family] = {
                route = route_owned,
                rule = rule_owned
            }
        end
    end
    return ownership
end

local function applied_routing_ownership()
    local settings = applied_routing()
    if not settings then return nil end
    return routing_ownership_for(settings, nil, true)
end

route_spec_active = function(spec)
    if not spec then return false end
    local routes = policy_route_entries(spec.family, spec.table)
    return policy_rule_present(spec) and policy_route_present(spec, routes)
end

local function route_spec_same_rule(left, right)
    return left and right and left.family == right.family and left.mark == right.mark and
        left.mask == right.mask and left.table == right.table
end

local function route_spec_same_route(left, right)
    return left and right and left.family == right.family and left.prefix == right.prefix and left.table == right.table
end

local function route_spec_equal(left, right)
    return route_spec_same_rule(left, right) and route_spec_same_route(left, right)
end

local function ownership_hint_value(ownership, family, kind)
    local configured = ownership and ownership["ipv" .. family]
    if configured and configured[kind] ~= nil then return configured[kind] == true end
    return nil
end

local function apply_route_settings(settings, previous, previous_ownership)
    local failures = {}
    local ownership = {}
    local route_ready = {}

    for _, family in ipairs({ "4", "6" }) do
        local spec = settings["ipv" .. family]
        if spec then
            local routes, route_error = policy_route_entries(family, spec.table)
            local family_ownership = {}
            ownership["ipv" .. family] = family_ownership
            if not routes then
                failures[#failures + 1] = route_error
            elseif not policy_route_present(spec, routes) then
                if exec_quiet(policy_route_add_command(spec)) then
                    family_ownership.route = true
                    route_ready[family] = true
                else
                    routes = policy_route_entries(family, spec.table)
                    if routes and policy_route_present(spec, routes) then
                        family_ownership.route = false
                        route_ready[family] = true
                    else
                        failures[#failures + 1] = policy_route_add_command(spec)
                    end
                end
            else
                local hint = ownership_hint_value(previous_ownership, family, "route")
                local previous_spec = previous and previous["ipv" .. family]
                family_ownership.route = hint ~= nil and hint or route_spec_same_route(spec, previous_spec)
                route_ready[family] = true
            end
        end
    end

    for _, family in ipairs({ "4", "6" }) do
        local spec = settings["ipv" .. family]
        if spec then
            local rules, rule_error = policy_rule_entries(family)
            local family_ownership = ownership["ipv" .. family]
            if not route_ready[family] then
                -- Do not leave an orphan fwmark rule behind when the matching
                -- local route could not be inspected or installed.
                failures[#failures + 1] = "IPv" .. family .. " local route is unavailable"
            elseif not rules then
                failures[#failures + 1] = rule_error
            elseif not policy_rule_present(spec, rules) then
                if exec_quiet(spec.rule) then
                    family_ownership.rule = true
                else
                    rules = policy_rule_entries(family)
                    if rules and policy_rule_present(spec, rules) then
                        family_ownership.rule = false
                    else
                        failures[#failures + 1] = spec.rule
                    end
                end
            else
                local hint = ownership_hint_value(previous_ownership, family, "rule")
                local previous_spec = previous and previous["ipv" .. family]
                family_ownership.rule = hint ~= nil and hint or route_spec_same_rule(spec, previous_spec)
            end
        end
    end

    local state = route_status(settings)
    if not state.ipv4 then failures[#failures + 1] = "IPv4 policy route verification" end
    if settings.ipv6_enabled and not state.ipv6 then failures[#failures + 1] = "IPv6 policy route verification" end
    return {
        ok = #failures == 0,
        active = #failures == 0 and state.active or false,
        ipv4 = state.ipv4,
        ipv6_active = state.ipv6,
        mark = settings.mark,
        table = settings.table,
        ipv6 = settings.ipv6_enabled,
        commands = settings.commands,
        ownership = ownership,
        error = #failures > 0 and ("policy route command or verification failed: " .. table.concat(failures, "; ")) or nil
    }
end

local function remove_route_settings(settings, preserve, ownership)
    if not settings then return true, {} end
    local failures = {}
    for _, family in ipairs({ "4", "6" }) do
        local old_spec = settings["ipv" .. family]
        if old_spec then
            local new_spec = preserve and preserve["ipv" .. family]
            if not route_spec_same_rule(old_spec, new_spec) and ownership_hint_value(ownership, family, "rule") == true then
                local removed, remove_error = clear_policy_rules(family, old_spec.mark, old_spec.mask, old_spec.table)
                if not removed then failures[#failures + 1] = remove_error end
            end
            if not route_spec_same_route(old_spec, new_spec) and ownership_hint_value(ownership, family, "route") == true then
                local routes, route_error = policy_route_entries(family, old_spec.table)
                if not routes then
                    failures[#failures + 1] = route_error
                else
                    local conflicting = false
                    local present = false
                    for _, entry in ipairs(routes) do
                        if entry.prefix == canonical_route_prefix(family, old_spec.prefix) then
                            if policy_route_matches(entry, old_spec) then present = true else conflicting = true end
                        end
                    end
                    if conflicting then
                        failures[#failures + 1] = "refusing to remove non-NftFlow IPv" .. family .. " route " .. tostring(old_spec.prefix)
                    elseif present and not exec_quiet(policy_route_delete_command(old_spec)) then
                        failures[#failures + 1] = "failed to delete NftFlow IPv" .. family .. " local route"
                    end
                end
            end
        end
    end
    return #failures == 0, failures
end

local function rollback_route_change(new_settings, old_settings, new_ownership, old_ownership)
    local removed, remove_failures = remove_route_settings(new_settings, old_settings, new_ownership)
    local restored = old_settings and apply_route_settings(old_settings, new_settings, old_ownership) or { ok = true, active = false }
    local result = {
        ok = removed and restored.ok == true,
        active = restored.active == true,
        removed = removed,
        restored = restored.ok == true
    }
    if not removed then result.error = "failed to remove new policy routes: " .. table.concat(remove_failures, "; ") end
    if restored.ok ~= true then result.error = (result.error and result.error .. "; " or "") .. (restored.error or "failed to restore old policy routes") end
    log_event(result.ok and "runtime rollback completed" or "runtime rollback failed: " .. (result.error or "unknown error"))
    return result
end

route_mode = function(mode, provided, preserve_previous)
    if mode ~= "add" and mode ~= "del" then
        return { ok = false, mode = mode, error = "route mode must be add or del" }
    end

    local settings = provided
    if not settings then
        local parsed, parse_error = routing_settings(read_file(ROUTING_SOURCE))
        if parsed then
            settings = parsed
        elseif mode == "add" then
            return { ok = false, mode = mode, error = parse_error }
        end
    end
    if not settings then
        settings = routing_settings(table.concat({
            "ip -4 route replace local 0.0.0.0/0 dev lo table " .. DEFAULT_ROUTING_TABLE,
            "ip -4 rule add fwmark " .. DEFAULT_FIREWALL_MARK .. "/" .. DEFAULT_FIREWALL_MARK .. " lookup " .. DEFAULT_ROUTING_TABLE,
            "ip -6 route replace local ::/0 dev lo table " .. DEFAULT_ROUTING_TABLE,
            "ip -6 rule add fwmark " .. DEFAULT_FIREWALL_MARK .. "/" .. DEFAULT_FIREWALL_MARK .. " lookup " .. DEFAULT_ROUTING_TABLE
        }, "\n"))
    end

    if mode == "add" then
        local previous = applied_routing()
        local previous_ownership = applied_routing_ownership()
        local result = apply_route_settings(settings, previous, previous_ownership)
        result.mode = mode
        if not result.ok then
            local rollback = rollback_route_change(settings, previous, result.ownership, previous_ownership)
            result.rollback_ok = rollback.ok == true
            if not result.rollback_ok then result.error = (result.error or "policy route apply failed") .. "; rollback failed" end
            return result
        end
        if not preserve_previous then
            local removed, remove_failures = remove_route_settings(previous, settings, previous_ownership)
            if not removed then
                local rollback = rollback_route_change(settings, previous, result.ownership, previous_ownership)
                result.rollback_ok = rollback.ok == true
                result.error = "failed to remove previous policy routes: " .. table.concat(remove_failures, "; ")
                if not result.rollback_ok then result.error = result.error .. "; rollback failed: " .. (rollback.error or "unknown error") end
                return result
            end
        end
        return result
    end

    local previous = applied_routing()
    local previous_ownership = applied_routing_ownership()
    local settings_ownership = previous and route_spec_equal(settings, previous) and previous_ownership or nil
    local removed, remove_failures = remove_route_settings(settings, nil, settings_ownership)
    local previous_removed = true
    local previous_failures = {}
    if previous then previous_removed, previous_failures = remove_route_settings(previous, nil, previous_ownership) end
    return {
        ok = removed and previous_removed,
        mode = mode,
        mark = settings.mark,
        table = settings.table,
        ipv6 = settings.ipv6_enabled,
        commands = settings.commands,
        active = false,
        error = not removed and ("failed to remove policy routes: " .. table.concat(remove_failures, "; ")) or
            not previous_removed and ("failed to remove previously applied policy routes: " .. table.concat(previous_failures, "; ")) or nil
    }
end

nft_transaction_content = function(current_tables, desired, desired_tables)
    local transaction, targets = {}, {}
    local function add_delete_targets(tables)
        for _, spec in ipairs(tables or {}) do
            local key = spec.family .. " " .. spec.name
            if spec.name == NFTFLOW_TABLE and not targets[key] then
                targets[key] = true
                if table_active(spec) then transaction[#transaction + 1] = table_command("delete", spec) end
            end
        end
    end

    add_delete_targets(current_tables)
    add_delete_targets(desired_tables)
    if desired and desired ~= "" then transaction[#transaction + 1] = desired end
    return table.concat(transaction, "\n")
end

local function run_nft_transaction(content)
    if trim(content) == "" then return true, "" end
    local apply_path = temporary_path(RUNTIME .. "/firewall-apply.nft")
    local saved, save_error = write_atomic(apply_path, content, 600)
    if not saved then return false, save_error end
    local check_ok, check_output = exec_capture("nft --check --file " .. shellquote(apply_path))
    if not check_ok then
        os.remove(apply_path)
        return false, trim(check_output)
    end
    local applied, apply_output = exec_capture("nft --file " .. shellquote(apply_path))
    os.remove(apply_path)
    if not applied then return false, trim(apply_output) end
    return true, ""
end

local function restore_runtime_file(path, value)
    if value == nil then
        os.remove(path)
        return true
    end
    local saved = write_atomic(path, value, 600)
    return saved == true
end

canonical_path = function(path)
    local ok, output = exec_capture("readlink -f " .. shellquote(path))
    return ok and trim(output) or path
end

process_pid = function(binary)
    local pid_raw = trim(read_file(PID_FILE))
    local pid = tonumber(pid_raw)
    if not pid or pid < 2 or pid % 1 ~= 0 then return nil end
    local expected = canonical_path(binary)
    local actual_ok, actual = exec_capture("readlink -f /proc/" .. tostring(pid) .. "/exe")
    if not exec_quiet("kill -0 " .. tostring(pid)) or not actual_ok or trim(actual) ~= trim(expected) then return nil end
    return pid
end

local function apply_firewall_runtime(raw, write_candidate)
    local normalized = normalize_firewall(raw)
    if write_candidate then
        local candidate_saved, candidate_error = write_atomic(RUNTIME_FIREWALL_CANDIDATE, normalized, 600)
        if not candidate_saved then return { ok = false, error = candidate_error } end
    end

    local checked = firewall_validate(normalized)
    if not checked.valid then return checked end

    local desired = checked.config
    local desired_tables = checked.tables
    local previous_snapshot = read_file(RUNTIME_FIREWALL_APPLIED)
    local current_tables = managed_firewall_tables()
    local current = previous_snapshot
    if current == nil and #current_tables > 0 then
        current = select(1, active_firewall(current_tables))
    end

    local transaction = nft_transaction_content(current_tables, desired, desired_tables)
    local applied, apply_error = run_nft_transaction(transaction)
    if not applied then
        return { ok = false, valid = false, error = "failed to load configured nftables tables", detail = apply_error }
    end

    local runtime_tables = managed_firewall_tables()
    local active, active_found, missing, active_count = active_firewall(runtime_tables)
    local verified = #runtime_tables == #desired_tables
    if verified then
        for _, spec in ipairs(desired_tables) do
            if not table_active(spec) then verified = false; break end
        end
    end
    if not verified then
        local restored, restore_error = run_nft_transaction(
            nft_transaction_content(runtime_tables, current or "", current_tables)
        )
        local detail = "runtime table verification failed"
        if not restored then detail = detail .. "; nft rollback failed: " .. (restore_error or "unknown error") end
        return { ok = false, valid = false, error = "configured firewall transaction failed verification", detail = detail }
    end

    local snapshot_saved, snapshot_error = write_atomic(RUNTIME_FIREWALL_APPLIED, desired, 600)
    if not snapshot_saved then
        local restored, restore_error = run_nft_transaction(
            nft_transaction_content(runtime_tables, current or "", current_tables)
        )
        restore_runtime_file(RUNTIME_FIREWALL_APPLIED, previous_snapshot)
        local detail = snapshot_error or "cannot save applied firewall snapshot"
        if not restored then detail = detail .. "; nft rollback failed: " .. (restore_error or "unknown error") end
        return { ok = false, valid = false, error = detail }
    end

    log_event("firewall applied")
    return {
        ok = true,
        applied = true,
        config = desired,
        applied_config = desired,
        active = active,
        active_found = active_found,
        missing_tables = missing,
        table_count = #runtime_tables,
        active_table_count = active_count
    }
end

local function remove_runtime_firewall()
    local current_tables = managed_firewall_tables()
    local removed, remove_error = run_nft_transaction(nft_transaction_content(current_tables, "", {}))
    if not removed then
        return { ok = false, error = "failed to remove configured nftables tables", detail = remove_error }
    end

    local remaining = managed_firewall_tables()
    if #remaining > 0 then
        return { ok = false, error = "some NftFlow nftables tables are still active" }
    end
    os.remove(RUNTIME_FIREWALL_CANDIDATE)
    os.remove(RUNTIME_FIREWALL_APPLIED)
    log_event("firewall removed")
    return { ok = true, enabled = false, active = "# No active NftFlow nftables objects were found.\n" }
end

local function firewall_mode(mode)
    if mode ~= "on" and mode ~= "off" then error("firewall mode must be on or off") end
    if mode == "off" then return remove_runtime_firewall() end
    local source = read_file(FIREWALL_SOURCE)
    if source == nil then return { ok = false, error = "cannot read " .. FIREWALL_SOURCE } end
    return apply_firewall_runtime(source, false)
end

local function firewall_apply(raw)
    raw = tostring(raw or "")
    return apply_firewall_runtime(raw, true)
end

local function firewall_apply_file(path)
    local raw, read_error = read_rpc_input(path)
    if raw == nil then return { ok = false, error = read_error } end
    return firewall_apply(raw)
end

local routing_apply

local function route_apply()
    return routing_apply(read_file(ROUTING_SOURCE), false)
end

routing_apply = function(raw, write_candidate)
    raw = tostring(raw or "")
    if #raw > EDITOR_MAX_BYTES then return { ok = false, error = "routing file is larger than 32 KiB" } end
    if raw:find("%z") then return { ok = false, error = "routing file contains a NUL byte" } end
    local normalized = raw:gsub("\r\n", "\n"):gsub("\r", "\n")
    if normalized ~= "" and normalized:sub(-1) ~= "\n" then normalized = normalized .. "\n" end
    if write_candidate then
        local candidate_saved, candidate_error = write_atomic(RUNTIME_ROUTING_CANDIDATE, normalized, 600)
        if not candidate_saved then return { ok = false, error = candidate_error } end
    end
    local checked = routing_validate(normalized)
    if not checked.valid then return checked end
    local settings = routing_settings(checked.config)
    local previous = applied_routing()
    local previous_ownership = applied_routing_ownership()
    local result = route_mode("add", settings, false)
    if not result.ok then
        return { ok = false, error = "failed to install policy routes", detail = result.error, rollback_ok = result.rollback_ok }
    end

    local route_state = route_status(settings)
    if not route_state.active then
        local rollback = rollback_route_change(settings, previous, result.ownership, previous_ownership)
        return { ok = false, error = "policy route verification failed", rollback_ok = rollback.ok }
    end

    local previous_snapshot = read_file(RUNTIME_ROUTING_APPLIED)
    local applied_saved, applied_error = write_atomic(RUNTIME_ROUTING_APPLIED, settings.normalized, 600)
    if not applied_saved then
        local rollback = rollback_route_change(settings, previous, result.ownership, previous_ownership)
        restore_runtime_file(RUNTIME_ROUTING_APPLIED, previous_snapshot)
        return { ok = false, error = applied_error, rollback_ok = rollback.ok }
    end

    log_event("policy routing applied")
    return {
        ok = true,
        applied = true,
        config = settings.normalized,
        applied_config = settings.normalized,
        routing_active = active_routing(settings),
        route_active = route_state.active,
        route_ipv4 = route_state.ipv4,
        route_ipv6 = route_state.ipv6,
        ipv6_enabled = settings.ipv6_enabled,
        policy_route_commands = policy_route_commands(settings),
        routing_config = settings.normalized,
        route_commands = settings.route_commands,
        rule_commands = settings.rule_commands,
        firewall_mark = settings.mark,
        routing_table = settings.table
    }
end

local function routing_validate_file(path)
    local raw, read_error = read_rpc_input(path)
    if raw == nil then return { ok = false, valid = false, error = read_error } end
    return routing_validate(raw)
end

local function routing_save_file(path)
    local raw, read_error = read_rpc_input(path)
    if raw == nil then return { ok = false, error = read_error } end
    return routing_save(raw)
end

local function routing_apply_file(path)
    local raw, read_error = read_rpc_input(path)
    if raw == nil then return { ok = false, error = read_error } end
    return routing_apply(raw, true)
end

local function remove_runtime_routing()
    local result = route_mode("del")
    if not result.ok then
        return { ok = false, error = result.error or "failed to remove policy routes" }
    end
    os.remove(RUNTIME_ROUTING_CANDIDATE)
    os.remove(RUNTIME_ROUTING_APPLIED)
    log_event("policy routing removed")
    return { ok = true, enabled = false, route_active = false }
end

local function process_identity(pid)
    if not pid then return nil, nil end
    local status = read_file("/proc/" .. tostring(pid) .. "/status") or ""
    return tonumber(status:match("\nUid:%s*(%d+)")), tonumber(status:match("\nGid:%s*(%d+)"))
end

local function file_info(path)
    local result = { exists = false, size = 0, mtime = nil }
    if not path or path == "" then return result end
    local ok, stat = pcall(function()
        return nixio_fs and nixio_fs.stat and nixio_fs.stat(path)
    end)
    if ok and type(stat) == "table" then
        local stat_type = tostring(stat.type or "")
        if stat_type == "" or stat_type == "reg" or stat_type == "file" then
            result.exists = stat.size ~= nil or stat_type ~= ""
            result.size = tonumber(stat.size) or 0
            result.mtime = tonumber(stat.mtime)
        end
    end
    if not result.exists then
        local exists, output = exec_capture("[ -f " .. shellquote(path) .. " ] && wc -c < " .. shellquote(path))
        if exists then
            result.exists = true
            result.size = tonumber(trim(output)) or 0
        end
    end
    return result
end

local function geo_main()
    local asset_dir = nonempty(uci_get("asset_dir", "/usr/share/xray")) or "/usr/share/xray"
    return {
        asset_dir = asset_dir,
        geoip_file = nonempty(uci_get("geoip_file", "")) or (asset_dir .. "/geoip.dat"),
        geosite_file = nonempty(uci_get("geosite_file", "")) or (asset_dir .. "/geosite.dat"),
        geoip_url = nonempty(uci_get("geoip_url", "")) or DEFAULT_GEOIP_URL,
        geosite_url = nonempty(uci_get("geosite_url", "")) or DEFAULT_GEBSITE_URL
    }
end

local function cleanup_geodata_temporary_files()
    local main = geo_main()
    for _, path in ipairs({ main.geoip_file, main.geosite_file }) do
        -- Quote the base path and leave only the fixed suffix wildcard outside
        -- the quotes, so configured paths remain shell-safe while all interrupted
        -- downloads are removed.
        exec_quiet("rm -f " .. shellquote(path) .. ".nftflow-download* " .. shellquote(path) .. ".nftflow-result*")
    end
end

local function geo_update_state_path(kind)
    return RUNTIME .. "/geo-update-" .. kind .. ".json"
end

local function geo_update_lock_path(kind)
    return RUNTIME .. "/geo-update-" .. kind .. ".lock"
end

local function geo_update_log_path(kind)
    return "/var/log/nftflow/geo-update-" .. kind .. ".log"
end

local function decode_geo_update_state(path)
    local raw = read_file(path)
    if not raw or trim(raw) == "" then return nil end
    local ok, state = pcall(json_decode, raw)
    if not ok or type(state) ~= "table" then
        return { ok = false, status = "failed", error = "cannot parse GeoData update state" }
    end
    return state
end

local function legacy_geo_update_state(kind)
    local state = decode_geo_update_state(GEO_UPDATE_STATE)
    if type(state) ~= "table" then return nil end
    if state.kind == kind then return state end
    if state.kind ~= "all" then return nil end
    if state.current_kind == kind then return state end
    if type(state.updates) == "table" and type(state.updates[kind]) == "table" then
        local result = {}
        for key, value in pairs(state.updates[kind]) do result[key] = value end
        result.kind = kind
        return result
    end
    return nil
end

local function read_geo_update_state(kind)
    local state = decode_geo_update_state(geo_update_state_path(kind))
    if state then
        state.kind = kind
        return state
    end
    return legacy_geo_update_state(kind) or { kind = kind, status = "idle" }
end

local function geo_update_process_alive(pid)
    pid = tonumber(pid)
    return pid and pid > 1 and pid % 1 == 0 and exec_quiet("kill -0 " .. tostring(math.floor(pid)))
end

local function geo_update_status(kind)
    local state = read_geo_update_state(kind)
    local now = os.time()
    local worker_missing = not state.pid
    local worker_alive = geo_update_process_alive(state.pid)
    local worker_dead = state.pid and not worker_alive
    if geo_update_active(state) and (worker_dead or
        (worker_missing and geo_update_state_expired(state, now))) then
        state.ok = false
        state.status = "failed"
        state.finished = now
        state.error = "GeoData update worker exited unexpectedly"
        state.pid = nil
        write_atomic(geo_update_state_path(kind), json_encode(state) .. "\n", 600)
        remove_geo_update_lock(kind)
    end
    return state
end

geo_update_active = function(state)
    return type(state) == "table" and (state.status == "running" or state.status == "starting")
end

geo_update_state_expired = function(state, now)
    if not geo_update_active(state) then return false end
    local started = tonumber(state.started)
    return not started or (now or os.time()) - started >= GEO_UPDATE_START_TIMEOUT
end

local function geo_release_version(output)
    return tostring(output or ""):match("/releases/download/([^/%s]+)/")
end

local function geo_save_progress(kind, downloaded)
    local state = read_geo_update_state(kind)
    if not geo_update_active(state) then return end
    state.ok = true
    state.status = "running"
    state.kind = kind
    state.progress = { downloaded = math.max(0, tonumber(downloaded) or 0) }
    write_atomic(geo_update_state_path(kind), json_encode(state) .. "\n", 600)
end

local function geo_asset_snapshot(main)
    local assets = {
        geoip = { kind = "geoip", path = main.geoip_file, url = main.geoip_url },
        geosite = { kind = "geosite", path = main.geosite_file, url = main.geosite_url }
    }
    for _, asset in pairs(assets) do
        local stat = file_info(asset.path)
        asset.exists = stat.exists
        asset.size = stat.size
        asset.mtime = stat.mtime
        asset.ready = stat.exists and stat.size > 0
    end
    return assets
end

local function geo_status_from_main(main)
    local assets = geo_asset_snapshot(main)
    local active = {}
    local missing = {}
    local due = {}
    local next_update
    local now = os.time()
    for _, kind in ipairs(GEO_KINDS) do
        local update = geo_update_status(kind)
        assets[kind].update = update
        assets[kind].local_version = update.local_version or update.source_version
        if geo_update_active(update) then active[#active + 1] = update end
        if not assets[kind].ready then missing[#missing + 1] = kind end
        local due_at = assets[kind].mtime and (assets[kind].mtime + GEO_AUTO_UPDATE_INTERVAL) or now
        if due_at <= now then due[#due + 1] = kind end
        if not next_update or due_at < next_update then next_update = due_at end
    end
    local update = { ok = true, status = "idle" }
    if #active == 1 then
        update = {}
        for key, value in pairs(active[1]) do update[key] = value end
    elseif #active > 1 then
        update = { ok = true, status = "running", kind = "all" }
    end
    local crontab = read_file("/etc/crontabs/root") or ""
    return {
        ok = true,
        ready = #missing == 0,
        missing = missing,
        assets = assets,
        update = update,
        auto_update = {
            scheduled = crontab:find(GEO_AUTO_UPDATE_TAG, 1, true) ~= nil,
            interval_days = math.floor(GEO_AUTO_UPDATE_INTERVAL / 86400),
            due = due,
            next_update = next_update
        }
    }
end

local function geo_request(url, target, head_only)
    url = nonempty(url)
    if not url or not url:match("^https://") then return false, "GeoData source URL must use HTTPS" end
    if not uclient_fetch_available() then return false, "uclient-fetch is unavailable" end
    local command = head_only
        and (UCLIENT_FETCH .. " -s -T 5 " .. shellquote(url))
        or (UCLIENT_FETCH .. " -q -T 5 -O " .. shellquote(target) .. " " .. shellquote(url))
    return exec_capture(command)
end

local function geo_kind_asset(main, kind)
    if kind ~= "geoip" and kind ~= "geosite" then error("unsupported geodata kind") end
    return geo_asset_snapshot(main)[kind]
end

local function geo_check(kind)
    local main, asset = geo_main(), nil
    asset = geo_kind_asset(main, kind)
    local ok, output = geo_request(asset.url, nil, true)
    local local_asset = geo_status_from_main(main).assets[kind]
    if not ok then return { ok = false, kind = kind, url = asset.url, local_asset = local_asset, error = output } end
    local remote_version = geo_release_version(output)
    local local_version = local_asset.local_version or (local_asset.update and (local_asset.update.local_version or local_asset.update.source_version))
    local update_available
    if remote_version and local_version then
        update_available = remote_version ~= local_version
    end
    return { ok = true, kind = kind, url = asset.url, local_asset = local_asset, local_version = local_version,
        remote_version = remote_version, update_available = update_available }
end

local function geo_download(url, target, on_progress)
    url = nonempty(url)
    if not url or not url:match("^https://") then return false, "GeoData source URL must use HTTPS" end
    if not uclient_fetch_available() then return false, "uclient-fetch is unavailable" end

    local result_file = temporary_path(RUNTIME .. "/geo-download-result")
    os.remove(result_file)
    local launch = string.format(
        "(%s -q -T 5 -O %s %s; printf '%%s' $? >%s) </dev/null >/dev/null 2>&1 & echo $!",
        shellquote(UCLIENT_FETCH),
        shellquote(target), shellquote(url), shellquote(result_file)
    )
    local pipe = io.popen(launch, "r")
    local pid = pipe and tonumber(trim(pipe:read("*l") or "")) or nil
    if pipe then pipe:close() end
    if not pid then os.remove(result_file); return false, "unable to start GeoData download" end

    local exit_code
    while not exit_code do
        local info = file_info(target)
        if on_progress then on_progress(info.size or 0) end
        local raw_result = read_file(result_file)
        if raw_result and trim(raw_result) ~= "" then
            exit_code = tonumber(trim(raw_result)) or 1
            break
        end
        exec_quiet("sleep 1")
    end
    os.remove(result_file)
    if exit_code == 0 then return true, "" end
    return false, "uclient-fetch exited with status " .. tostring(exit_code)
end

local function geo_update(kind)
    local main, asset = geo_main(), nil
    asset = geo_kind_asset(main, kind)
    if not mkdirp(dirname(asset.path)) then return { ok = false, kind = kind, error = "cannot create " .. dirname(asset.path) } end
    local temporary = temporary_path(asset.path .. ".nftflow-download")
    os.remove(temporary)
    local head_ok, head_output = geo_request(asset.url, nil, true)
    local source_version = head_ok and geo_release_version(head_output) or nil
    local downloaded, output = geo_download(asset.url, temporary, function(size) geo_save_progress(kind, size) end)
    if not downloaded then os.remove(temporary); return { ok = false, kind = kind, url = asset.url, error = output } end
    local downloaded_info = file_info(temporary)
    if not downloaded_info.exists or downloaded_info.size < 1024 then
        os.remove(temporary)
        return { ok = false, kind = kind, url = asset.url, error = "downloaded GeoData file is empty or implausibly small" }
    end
    if not os.rename(temporary, asset.path) then os.remove(temporary); return { ok = false, error = "cannot atomically replace " .. asset.path } end
    exec_quiet("chmod 0644 " .. shellquote(asset.path))
    local result = geo_status_from_main(main)
    result.kind, result.updated = kind, true
    result.source_version, result.local_version = source_version, source_version
    result.message = kind .. " updated; reload Xray if it already loaded the old asset"
    return result
end

remove_geo_update_lock = function(kind)
    exec_quiet("rmdir " .. shellquote(geo_update_lock_path(kind)))
end

local function geo_update_worker(kind)
    if kind ~= "geoip" and kind ~= "geosite" then error("unsupported geodata kind") end
    local state_path = geo_update_state_path(kind)
    local running_state = read_geo_update_state(kind)
    running_state.ok = true
    running_state.status = "running"
    running_state.kind = kind
    running_state.automatic = false
    running_state.started = running_state.started or os.time()
    running_state.pid = nixio.getpid()
    running_state.progress = { downloaded = 0 }
    local running_saved, running_error = write_atomic(state_path, json_encode(running_state) .. "\n", 600)
    if not running_saved then
        remove_geo_update_lock(kind)
        return { ok = false, kind = kind, status = "failed", error = running_error or "cannot save GeoData update state" }
    end
    local ok, result = pcall(geo_update, kind)
    if not ok then result = { ok = false, kind = kind, error = tostring(result) } end
    if type(result) ~= "table" then result = { ok = false, kind = kind, error = "GeoData update returned no result" } end
    result.kind = kind
    result.status = result.ok == true and "done" or "failed"
    result.finished = os.time()
    if not result.local_version then result.local_version = running_state.local_version or running_state.source_version end
    local saved, err = write_atomic(state_path, json_encode(result) .. "\n", 600)
    remove_geo_update_lock(kind)
    if not saved then
        return { ok = false, kind = kind, status = "failed", error = err or "cannot save GeoData update state" }
    end
    return result
end

local function geo_update_start(kind)
    if kind ~= "geoip" and kind ~= "geosite" then error("unsupported geodata kind") end
    if not mkdirp(RUNTIME) or not mkdirp("/var/log/nftflow") then
        return { ok = false, kind = kind, error = "cannot create GeoData runtime directory" }
    end

    local state_path = geo_update_state_path(kind)
    local lock_path = geo_update_lock_path(kind)
    local current = geo_update_status(kind)
    local lock_exists = exec_quiet("[ -d " .. shellquote(lock_path) .. " ]")
    local worker_alive = geo_update_active(current) and geo_update_process_alive(current.pid)
    if worker_alive or (geo_update_active(current) and lock_exists) then
        current.ok = true
        current.already_running = worker_alive
        return current
    end
    if lock_exists then remove_geo_update_lock(kind) end
    if not exec_quiet("mkdir " .. shellquote(lock_path)) then
        return { ok = false, kind = kind, status = "busy", error = "another GeoData update is starting" }
    end

    local state = {
        ok = true,
        status = "starting",
        kind = kind,
        started = os.time(),
        local_version = current.local_version or current.source_version,
        progress = { downloaded = 0 },
        message = "GeoData download started"
    }
    local saved, err = write_atomic(state_path, json_encode(state) .. "\n", 600)
    if not saved then
        remove_geo_update_lock(kind)
        return { ok = false, kind = kind, error = err or "cannot save GeoData update state" }
    end

    local launch = string.format(
        "/usr/bin/lua /usr/libexec/nftflow/nftflowctl.lua geo update-worker %s </dev/null >%s 2>&1 & echo $!",
        shellquote(kind), shellquote(geo_update_log_path(kind))
    )
    local pipe = io.popen(launch, "r")
    local pid = pipe and tonumber(trim(pipe:read("*l") or "")) or nil
    if pipe then pipe:close() end
    if not pid then
        remove_geo_update_lock(kind)
        state.ok = false
        state.status = "failed"
        state.error = "unable to start GeoData update worker"
        write_atomic(state_path, json_encode(state) .. "\n", 600)
        return state
    end

    state.pid = pid
    local pid_saved, pid_error = write_atomic(state_path, json_encode(state) .. "\n", 600)
    if not pid_saved then
        if geo_update_process_alive(pid) then terminate_pid(pid) end
        remove_geo_update_lock(kind)
        state.ok = false
        state.status = "failed"
        state.finished = os.time()
        state.error = pid_error or "cannot save GeoData worker PID"
        write_atomic(state_path, json_encode(state) .. "\n", 600)
        return state
    end
    return state
end

local function geo_auto_update_one(kind)
    local state_path = geo_update_state_path(kind)
    local lock_path = geo_update_lock_path(kind)
    local current = geo_update_status(kind)
    local worker_alive = geo_update_active(current) and geo_update_process_alive(current.pid)
    local lock_exists = exec_quiet("[ -d " .. shellquote(lock_path) .. " ]")
    if worker_alive or (geo_update_active(current) and lock_exists) then
        return { ok = true, kind = kind, status = "busy", automatic = true, message = "another " .. kind .. " update is already running" }
    end
    if lock_exists then remove_geo_update_lock(kind) end
    if not exec_quiet("mkdir " .. shellquote(lock_path)) then
        return { ok = true, kind = kind, status = "busy", automatic = true, message = kind .. " update is starting" }
    end

    local state = {
        ok = true,
        status = "running",
        kind = kind,
        automatic = true,
        started = os.time(),
        pid = nixio.getpid(),
        local_version = current.local_version or current.source_version,
        progress = { downloaded = 0 }
    }
    local saved, err = write_atomic(state_path, json_encode(state) .. "\n", 600)
    if not saved then
        remove_geo_update_lock(kind)
        return { ok = false, kind = kind, status = "failed", automatic = true, error = err or "cannot save GeoData update state" }
    end

    local call_ok, result = pcall(geo_update, kind)
    if not call_ok then result = { ok = false, error = tostring(result) } end
    local success = result and result.ok == true
    state.ok = success
    state.status = success and "done" or "failed"
    state.finished = os.time()
    state.updated = success
    state.message = success and (kind .. " automatic update completed") or (kind .. " automatic update failed")
    if success then
        state.source_version = result.source_version or state.source_version
        state.local_version = result.local_version or result.source_version or state.local_version
    end
    if not success then state.error = result and result.error or "GeoData update failed" end
    saved, err = write_atomic(state_path, json_encode(state) .. "\n", 600)
    remove_geo_update_lock(kind)
    if not saved then
        return { ok = false, kind = kind, status = "failed", automatic = true, error = err or "cannot save GeoData update state" }
    end
    return state
end

local function geo_auto_update()
    local main = geo_main()
    local snapshot = geo_status_from_main(main)
    local due = snapshot.auto_update and snapshot.auto_update.due or {}
    if #due == 0 then
        return {
            ok = true,
            status = "skipped",
            automatic = true,
            next_update = snapshot.auto_update and snapshot.auto_update.next_update,
            message = "GeoData is not due for its monthly update"
        }
    end
    if not mkdirp(RUNTIME) or not mkdirp("/var/log/nftflow") then
        return { ok = false, status = "failed", automatic = true, error = "cannot create GeoData runtime directory" }
    end

    local summary = { ok = true, status = "done", automatic = true, updates = {}, updated = 0 }
    for _, kind in ipairs(due) do
        local result = geo_auto_update_one(kind)
        summary.updates[kind] = {
            ok = result.ok,
            status = result.status,
            kind = kind,
            error = result.error,
            message = result.message
        }
        if result.status == "done" and result.ok == true then
            summary.updated = summary.updated + 1
        elseif result.status ~= "busy" then
            summary.ok = false
            summary.status = "failed"
        end
    end
    if summary.ok then
        summary.message = "Monthly GeoData update completed for " .. tostring(summary.updated) .. " file(s)"
    else
        summary.message = "Monthly GeoData update completed with errors"
        summary.error = "one or more GeoData files could not be updated"
    end
    return summary
end

terminate_pid = function(pid)
    pid = tonumber(pid)
    if not pid or pid < 2 or not exec_quiet("kill -0 " .. tostring(math.floor(pid))) then return true end
    exec_quiet("kill -TERM " .. tostring(math.floor(pid)))
    for _ = 1, 5 do
        if not exec_quiet("kill -0 " .. tostring(math.floor(pid))) then return true end
        exec_quiet("sleep 1")
    end
    exec_quiet("kill -KILL " .. tostring(math.floor(pid)))
    return not exec_quiet("kill -0 " .. tostring(math.floor(pid)))
end

local function cleanup_runtime()
    local main_ok, main = pcall(build_main)
    if main_ok then
        local pid = process_pid(nonempty(main.xray_bin) or "/usr/bin/xray")
        if pid and not terminate_pid(pid) then
            return { ok = false, error = "cannot stop Xray process " .. tostring(pid) }
        end
    end
    for _, kind in ipairs(GEO_KINDS) do
        local state = geo_update_status(kind)
        if state and geo_update_active(state) and state.pid and
            geo_update_process_alive(state.pid) then
            if not terminate_pid(state.pid) then
                return { ok = false, error = "cannot stop GeoData update worker " .. kind }
            end
        end
        remove_geo_update_lock(kind)
        os.remove(geo_update_state_path(kind))
    end
    local rpc_cleaned, rpc_cleanup_error = cleanup_all_rpc_temporary_dirs()
    if not rpc_cleaned then return { ok = false, error = rpc_cleanup_error } end
    cleanup_geodata_temporary_files()
    local firewall_removed = remove_runtime_firewall()
    if not firewall_removed.ok then return firewall_removed end
    local routing_removed = remove_runtime_routing()
    if not routing_removed.ok then return routing_removed end
    remove_runtime_temporary_files()
    os.remove(STATE_FILE)
    os.remove(PID_FILE)
    return { ok = true, cleaned = true }
end

local function procd_service_state()
    local request = '{"name":"nftflow"}'
    local ok, output = exec_capture("ubus -S call service list " .. shellquote(request))
    if not ok then return nil end
    local parsed_ok, parsed = pcall(json_decode, output)
    if not parsed_ok or type(parsed) ~= "table" then return nil end
    local service = parsed.nftflow
    if type(service) ~= "table" or type(service.instances) ~= "table" then
        return { managed = false, running = false }
    end
    for _, instance in pairs(service.instances) do
        if type(instance) == "table" and (instance.running == true or instance.running == 1) then
            return { managed = true, running = true, instance = instance }
        end
    end
    return { managed = true, running = false }
end

local function status()
    local ok, main = pcall(build_main)
    if not ok then return { ok = false, error = main } end
    local raw = read_file(main.config_file)
    local _, syntax_error = parse_document(raw, main.config_file)
    local pid = process_pid(nonempty(main.xray_bin) or "/usr/bin/xray")
    local version_ok, version_output = exec_capture("apk list --installed luci-app-nftflow 2>/dev/null")
    local app_version = version_ok and trim(version_output):match("^luci%-app%-nftflow%-([^%s]+)") or nil
    local uid, gid = process_identity(pid)
    local firewall_source = read_file(FIREWALL_SOURCE) or ""
    local applied_firewall = read_applied_firewall()
    local runtime_tables = managed_firewall_tables()
    local _, active_found, missing_tables, active_table_count = active_firewall(runtime_tables)
    local firewall_active = active_found
    local routing_settings_value
    local routing_error
    local routing_raw = read_file(ROUTING_SOURCE)
    if routing_raw then
        routing_settings_value, routing_error = routing_settings(routing_raw)
    else
        routing_error = "cannot read " .. ROUTING_SOURCE
    end
    local applied_routing_value = read_applied_routing()
    local routing = applied_routing_value and route_status(applied_routing_value) or { active = false, ipv4 = false, ipv6 = false }
    local runtime = read_runtime_state() or {}
    local procd = procd_service_state()
    local runtime_state = runtime.state
    if not RUNTIME_STATES[runtime_state] then runtime_state = pid and "starting" or "stopped" end
    if pid and (runtime_state == "failed" or runtime_state == "stopped") then runtime_state = "starting" end
    if not pid and (runtime_state == "starting" or runtime_state == "ready") then runtime_state = "failed" end
    if not pid and runtime_state == "stopping" then runtime_state = "stopped" end
    local started = tonumber(runtime.started)
    local uptime = pid and started and math.max(0, os.time() - started) or nil
    return {
        ok = true,
        running = pid ~= nil,
        process = pid ~= nil,
        procd_managed = procd and procd.managed or nil,
        procd_running = procd and procd.running or nil,
        runtime_state = runtime_state,
        state_error = runtime.error,
        app_version = app_version,
        pid = pid,
        uid = uid,
        gid = gid,
        uid_ok = pid ~= nil and uid == 0 or nil,
        expected_gid = main.run_gid,
        gid_ok = pid ~= nil and gid == main.run_gid or nil,
        enabled = main.enabled,
        uptime = uptime,
        restart_count = tonumber(runtime.restart_count) or 0,
        config_file = main.config_file,
        config_bytes = raw and #raw or 0,
        config_valid = syntax_error == nil,
        config_error = syntax_error,
        firewall_active = firewall_active,
        route_active = routing.active,
        route_ipv6 = routing.ipv6,
        routing_configured = routing_settings_value ~= nil,
        routing_error = routing_error,
        policy_route_commands = applied_routing_value and policy_route_commands(applied_routing_value) or
            routing_settings_value and policy_route_commands(routing_settings_value) or {},
        firewall_table_count = #runtime_tables,
        firewall_active_table_count = active_table_count,
        firewall_missing_tables = missing_tables,
        firewall_saved_bytes = #firewall_source,
        firewall_applied = applied_firewall ~= nil,
        routing_applied = applied_routing_value ~= nil
    }
end

local function health()
    local current = status()
    if not current.ok then return current end
    local process = current.running == true
    local firewall = current.firewall_active == true
    local routing = current.route_active == true
    local procd = current.procd_managed ~= false and
        (current.procd_managed ~= true or current.procd_running == process)
    local healthy = process and firewall and routing and procd
    return {
        ok = healthy,
        process = process,
        procd = procd,
        firewall = firewall,
        firewall_active = current.firewall_active == true,
        routing = routing,
        runtime_state = current.runtime_state,
        pid = current.pid,
        error = healthy and nil or "one or more runtime health checks failed"
    }
end

local function connectivity_test(target)
    local spec = CONNECTIVITY_TARGETS[trim(target)]
    if not spec then return { ok = false, error = "unsupported connectivity target" } end

    if not uclient_fetch_available() then
        return { ok = false, target = target, label = spec.label, error = "uclient-fetch is unavailable" }
    end
    local command = UCLIENT_FETCH .. " -q -T 5 -O /dev/null " .. shellquote(spec.url) .. " && echo '200 0'"

    local started_seconds, started_microseconds = nixio.gettimeofday()
    local requested, output = exec_capture(command)
    local ended_seconds, ended_microseconds = nixio.gettimeofday()
    local measured_seconds = math.max(0,
        (ended_seconds - started_seconds) + (ended_microseconds - started_microseconds) / 1000000)
    local clean_output = trim(output)
    local status, seconds = clean_output:match("(%d%d%d)%s+([%d%.]+)")
    if not status then
        return { ok = true, target = target, label = spec.label, url = spec.url, reachable = false, error = requested and "connectivity test returned no HTTP status" or clean_output }
    end

    status = tonumber(status)
    seconds = measured_seconds or tonumber(seconds) or 0
    local result = {
        ok = true,
        target = target,
        label = spec.label,
        url = spec.url,
        reachable = status >= 100 and status < 600 and status ~= 0,
        status = status,
        elapsed_ms = math.floor(seconds * 1000 + 0.5)
    }
    if status == 0 then
        result.error = trim(clean_output:gsub("^%d%d%d%s+[%d%.]+%s*", "", 1))
        if result.error == "" then result.error = "network request failed" end
    end
    return result
end

local function action(name)
    if name ~= "start" and name ~= "stop" and name ~= "restart" and name ~= "reload" then
        error("unsupported service action: " .. tostring(name))
    end
    local requested_action = name
    local force_start = requested_action == "start" or requested_action == "restart"
    local init_action = requested_action == "reload" and "restart" or requested_action
    local prefix = force_start and "NFTFLOW_FORCE_START=1 " or ""
    local ok, output = exec_capture(prefix .. "/etc/init.d/nftflow " .. shellquote(init_action))
    local current = status()
    if not ok then
        return { ok = false, action = requested_action, init_action = init_action, accepted = false, detail = trim(output), status = current }, 1
    end
    -- procd owns the asynchronous lifecycle.  LuCI observes the transition via
    -- status polling instead of holding an RPC request for the startup window.
    return {
        ok = true,
        action = requested_action,
        init_action = init_action,
        accepted = true,
        runtime_state = current.runtime_state,
        detail = trim(output),
        status = current
    }, 0
end

local function config_dump()
    local ok, main = pcall(build_main)
    if not ok then return { ok = false, error = main } end
    local config, raw, err = load_config(main.config_file)
    if not config then return { ok = false, error = err } end
    return { ok = true, config = config, path = main.config_file, bytes = #raw, source = "hand-written JSON file" }
end

local function dispatch(command, args)
    if command == "prepare" then
        mkdirp(RUNTIME)
        mkdirp("/etc/nftflow")
        mkdirp("/var/log/nftflow")
        os.remove(RUNTIME .. "/runtime.log")
        os.remove(RUNTIME .. "/runtime-log.json")
        os.remove(RUNTIME .. "/xray-output.fifo")
        remove_runtime_temporary_files()
        cleanup_geodata_temporary_files()
        return { ok = true }
    elseif command == "service-sync" then
        return service_sync()
    elseif command == "cleanup" then
        return cleanup_runtime()
    elseif command == "state" then
        local state, state_error = write_runtime_state(args[1] or "", args[2], args[3])
        if not state then return { ok = false, error = state_error } end
        return { ok = true, state = state }
    elseif command == "config-read" then
        return config_read()
    elseif command == "config-save" then
        return config_save(args[1])
    elseif command == "config-save-file" then
        return config_save_file(args[1])
    elseif command == "firewall" then
        return firewall_mode(args[1] or "on")
    elseif command == "firewall-read" then
        return firewall_read()
    elseif command == "firewall-validate" then
        return firewall_validate(args[1])
    elseif command == "firewall-validate-file" then
        return firewall_validate_file(args[1])
    elseif command == "firewall-save" then
        return firewall_save(args[1])
    elseif command == "firewall-save-file" then
        return firewall_save_file(args[1])
    elseif command == "firewall-apply" then
        return firewall_apply(args[1])
    elseif command == "firewall-apply-file" then
        return firewall_apply_file(args[1])
    elseif command == "route-apply" then
        return route_apply()
    elseif command == "routing-read" then
        return routing_read()
    elseif command == "routing-validate" then
        return routing_validate(args[1])
    elseif command == "routing-validate-file" then
        return routing_validate_file(args[1])
    elseif command == "routing-save" then
        return routing_save(args[1])
    elseif command == "routing-save-file" then
        return routing_save_file(args[1])
    elseif command == "routing-apply" then
        return routing_apply(args[1])
    elseif command == "routing-apply-file" then
        return routing_apply_file(args[1])
    elseif command == "route" then
        return route_mode(args[1] or "add")
    elseif command == "status" then
        return status()
    elseif command == "health" then
        return health()
    elseif command == "connectivity-test" then
        return connectivity_test(args[1])
    elseif command == "geo" then
        if args[1] == "status" then return geo_status_from_main(geo_main()) end
        if args[1] == "check" then return geo_check(args[2]) end
        if args[1] == "update" then return geo_update_start(args[2]) end
        if args[1] == "update-worker" then return geo_update_worker(args[2]) end
        if args[1] == "auto-update" then return geo_auto_update() end
        error("unknown geo command: " .. tostring(args[1]))
    elseif command == "config-dump" then
        return config_dump()
    elseif command == "reload" then
        return action("reload")
    elseif command == "action" then
        return action(args[1])
    end
    error("unknown command: " .. tostring(command))
end

(function()
    local command = arg[1] or ""
    local args = {}
    for index = 2, #arg do args[#args + 1] = arg[index] end
    local output_command = command == "status" or command == "health" or command == "state" or command == "config-read" or command == "config-save" or command == "config-save-file" or
        command == "config-dump" or command == "action" or command == "reload" or command == "prepare" or command == "cleanup" or
        command == "firewall" or command == "firewall-read" or command == "firewall-validate" or
        command == "firewall-validate-file" or command == "firewall-save" or command == "firewall-save-file" or command == "firewall-apply" or command == "firewall-apply-file" or command == "route-apply" or
        command == "routing-read" or command == "routing-validate" or command == "routing-save" or command == "routing-apply" or
        command == "routing-validate-file" or command == "routing-save-file" or command == "routing-apply-file" or
        command == "route" or
        command == "connectivity-test" or command == "geo"
    local ok, result, code = pcall(dispatch, command, args)
    if not ok then
        result = { ok = false, error = tostring(result) }
        code = 1
    elseif type(result) ~= "table" then
        result = { ok = true, result = result }
        code = code or 0
    else
        code = code or (result.ok == false and 1 or 0)
    end

    if output_command then
        io.write(json_encode(result) .. "\n")
    elseif not ok then
        io.stderr:write((result.error or "xrayctl failed") .. "\n")
    end
    os.exit(code)
end)()
