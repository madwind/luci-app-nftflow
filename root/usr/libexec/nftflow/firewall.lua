#!/usr/bin/lua
-- SPDX-License-Identifier: Apache-2.0
-- NftFlow nftables frontend with narrowly scoped %geoip:<tag>% expansion.

local jsonc = require "luci.jsonc"
local nixio = require "nixio"
local geoip = dofile "/usr/libexec/nftflow/geoip.lua"
local nft_source = dofile "/usr/libexec/nftflow/nft-source.lua"

local RUNTIME = "/var/run/nftflow"
local FIREWALL_SOURCE = "/etc/nftflow/firewall.nft"
local CANDIDATE = RUNTIME .. "/firewall.candidate.nft"
local APPLIED_SOURCE = RUNTIME .. "/firewall.applied.nft"
local APPLIED_COMPILED = RUNTIME .. "/firewall.applied.compiled.nft"
local EDITOR_MAX_BYTES = 32 * 1024
local OWNED_TABLE = "nftflow"
local temporary_sequence = 0

local function json_encode(value)
    if jsonc.stringify then return jsonc.stringify(value) end
    return jsonc.encode(value)
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

local function mkdirp(path)
    return exec_quiet("mkdir -p " .. shellquote(path))
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
    local parent = path:match("^(.*)/[^/]*$") or "."
    if not mkdirp(parent) then return false, "cannot create " .. parent end
    local temporary = temporary_path(path)
    local file, open_error = io.open(temporary, "w")
    if not file then return false, open_error or "cannot open temporary file" end
    local written, write_error = file:write(value)
    if not written then file:close(); os.remove(temporary); return false, write_error or "cannot write temporary file" end
    local closed, close_error = file:close()
    if not closed then os.remove(temporary); return false, close_error or "cannot close temporary file" end
    if mode then exec_quiet("chmod " .. tostring(mode) .. " " .. shellquote(temporary)) end
    if not os.rename(temporary, path) then os.remove(temporary); return false, "cannot replace " .. path end
    if mode then exec_quiet("chmod " .. tostring(mode) .. " " .. shellquote(path)) end
    return true
end

local function restore_file(path, value)
    if value == nil then os.remove(path); return true end
    return write_atomic(path, value, 600) == true
end

local function uci_get(option, default)
    local ok, output = exec_capture("/sbin/uci -q get nftflow.main." .. option)
    output = trim(output)
    return ok and output ~= "" and output or default
end

local function geoip_path()
    local configured = trim(uci_get("geoip_file", ""))
    if configured ~= "" then return configured end
    local asset_dir = trim(uci_get("asset_dir", "/usr/share/xray"))
    if asset_dir == "" then asset_dir = "/usr/share/xray" end
    return asset_dir .. "/geoip.dat"
end

local function normalize(raw)
    raw = tostring(raw or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if raw ~= "" and raw:sub(-1) ~= "\n" then raw = raw .. "\n" end
    return raw
end

local function add_warning(warnings, seen, message)
    if seen[message] then return end
    seen[message] = true
    warnings[#warnings + 1] = message
end

local function omit_empty_macro(segment, raw, next_position)
    local without_comma, removed = segment:gsub(",%s*$", "", 1)
    if removed > 0 then return without_comma, next_position end

    local tail = raw:sub(next_position)
    local _, finish = tail:find("^%s*,")
    if finish then return segment, next_position + finish end
    return segment, next_position
end

local function remove_empty_elements_blocks(raw)
    local parsed = nft_source.parse(raw)
    if not parsed then return raw end

    local removals = {}
    for _, set_spec in ipairs(parsed.sets) do
        if set_spec.elements_start and trim(set_spec.elements_body or "") == "" then
            removals[#removals + 1] = {
                start_position = set_spec.elements_start,
                finish_position = set_spec.elements_close
            }
        end
    end

    table.sort(removals, function(left, right)
        return left.start_position > right.start_position
    end)
    for _, removal in ipairs(removals) do
        raw = raw:sub(1, removal.start_position - 1) .. raw:sub(removal.finish_position + 1)
    end
    return raw
end

local function queue_geoip_elements(deferred, order, set_spec, values)
    local bucket = deferred[set_spec.key]
    if not bucket then
        bucket = { spec = set_spec, values = {}, seen = {} }
        deferred[set_spec.key] = bucket
        order[#order + 1] = bucket
    end
    for _, value in ipairs(values) do
        if not bucket.seen[value] then
            bucket.seen[value] = true
            bucket.values[#bucket.values + 1] = value
        end
    end
end

local function append_geoip_elements(output, order)
    for _, bucket in ipairs(order) do
        if #bucket.values > 0 then
            output[#output + 1] = string.format(
                "\nadd element %s %s %s { %s }\n",
                bucket.spec.table_family, bucket.spec.table_name, bucket.spec.name,
                table.concat(bucket.values, ", ")
            )
        end
    end
end

local function compile(raw)
    local parsed, parse_error = nft_source.inspect(raw, OWNED_TABLE)
    if not parsed then return nil, nil, parse_error end

    local warnings, warning_seen = {}, {}
    if #parsed.macros == 0 then return raw, parsed, nil, warnings end

    local cache, output, position = {}, {}, 1
    local deferred, deferred_order = {}, {}
    local path = geoip_path()
    for _, macro in ipairs(parsed.macros) do
        local segment = raw:sub(position, macro.start_position - 1)
        local next_position = macro.finish_position + 1
        local key = string.upper(macro.tag)

        if cache[key] == nil then
            local data, data_error, data_kind = geoip.load(path, key)
            if not data then
                if data_kind == "missing_file" or data_kind == "missing_tag" then
                    cache[key] = { ipv4 = {}, ipv6 = {}, missing = true }
                    add_warning(warnings, warning_seen,
                        "geoip:" .. macro.tag .. " is unavailable in " .. path .. "; macro ignored")
                else
                    return nil, nil, data_error
                end
            else
                cache[key] = data
            end
        end

        local values = macro.family == 4 and cache[key].ipv4 or cache[key].ipv6
        if #values == 0 then
            if not cache[key].missing then
                add_warning(warnings, warning_seen,
                    "geoip:" .. macro.tag .. " has no IPv" .. tostring(macro.family) .. " CIDRs; macro ignored")
            end
        else
            queue_geoip_elements(deferred, deferred_order, macro.set, values)
        end

        segment, next_position = omit_empty_macro(segment, raw, next_position)
        output[#output + 1] = segment
        position = next_position
    end
    output[#output + 1] = raw:sub(position)

    local compiled_output = { remove_empty_elements_blocks(table.concat(output)) }
    append_geoip_elements(compiled_output, deferred_order)
    return table.concat(compiled_output), parsed, nil, warnings
end

local function table_command(verb, spec)
    return verb .. " table " .. spec.family .. " " .. spec.name
end

local function table_active(spec)
    return exec_quiet(table_command("nft list", spec))
end

local function managed_tables()
    local tables, seen = {}, {}
    local listed, output = exec_capture("nft list tables")
    if not listed then return tables end
    for line in (output .. "\n"):gmatch("(.-)\n") do
        local family, name = trim(line):match("^table%s+(%S+)%s+(%S+)$")
        local key = family and name and family .. " " .. name or nil
        if name == OWNED_TABLE and not seen[key] then
            seen[key] = true
            tables[#tables + 1] = { family = family, name = name, key = key }
        end
    end
    return tables
end

local function active_firewall(tables, source, fold)
    tables = tables or managed_tables()
    local output, missing = {}, {}
    local source_sets = fold and nft_source.macro_sets(source, OWNED_TABLE) or {}
    for _, spec in ipairs(tables) do
        local ok, listed = exec_capture(table_command("nft list", spec))
        if ok and trim(listed) ~= "" then
            local value = trim(listed)
            if fold then value = nft_source.fold_runtime(value, source_sets) end
            output[#output + 1] = value
        else
            missing[#missing + 1] = spec.key
        end
    end
    local active = #output > 0 and table.concat(output, "\n") .. "\n" or
        "# No managed NftFlow nftables tables were found.\n"
    if #tables == 0 then return active, false, {}, 0 end
    if #missing > 0 then return active, false, missing, #output end
    return active, true, {}, #output
end

local function transaction(current_tables, desired, desired_tables)
    local lines, targets = {}, {}
    local function add_deletes(tables)
        for _, spec in ipairs(tables or {}) do
            local key = spec.family .. " " .. spec.name
            if spec.name == OWNED_TABLE and not targets[key] then
                targets[key] = true
                if table_active(spec) then lines[#lines + 1] = table_command("delete", spec) end
            end
        end
    end
    add_deletes(current_tables)
    add_deletes(desired_tables)
    if desired and desired ~= "" then lines[#lines + 1] = desired end
    return table.concat(lines, "\n")
end

local function run_transaction(content)
    if trim(content) == "" then return true, "" end
    local path = temporary_path(RUNTIME .. "/firewall-apply.nft")
    local saved, save_error = write_atomic(path, content, 600)
    if not saved then return false, save_error end
    local checked, check_output = exec_capture("nft --check --file " .. shellquote(path))
    if not checked then os.remove(path); return false, trim(check_output) end
    local applied, apply_output = exec_capture("nft --file " .. shellquote(path))
    os.remove(path)
    if not applied then return false, trim(apply_output) end
    return true, ""
end

local function validate(raw)
    raw = tostring(raw or "")
    if #raw > EDITOR_MAX_BYTES then return { ok = false, valid = false, error = "firewall file is larger than 32 KiB" } end
    if raw:find("%z") then return { ok = false, valid = false, error = "firewall file contains a NUL byte" } end
    local source = normalize(raw)
    local compiled, parsed, compile_error, warnings = compile(source)
    if not compiled then return { ok = false, valid = false, error = compile_error } end
    if not mkdirp(RUNTIME) then return { ok = false, valid = false, error = "cannot create " .. RUNTIME } end
    local path = temporary_path(RUNTIME .. "/firewall-check.nft")
    local saved, save_error = write_atomic(path, compiled, 600)
    if not saved then return { ok = false, valid = false, error = save_error } end
    local pipe = io.popen("nft --check --file " .. shellquote(path) .. " 2>&1; printf '\\n__NFTFLOW_NFT_RC__%s\\n' \"$?\"")
    local detail = pipe and (pipe:read("*a") or "") or "unable to execute nft"
    if pipe then pipe:close() end
    local exit_code = tonumber(detail:match("__NFTFLOW_NFT_RC__(%d+)"))
    detail = detail:gsub("\n?__NFTFLOW_NFT_RC__%d+%s*$", "")
    os.remove(path)
    local valid = exit_code == 0
    local result = {
        ok = valid, valid = valid, detail = trim(detail), config = source, compiled = compiled,
        bytes = #source, tables = parsed.tables, geoip_macros = #parsed.macros, warnings = warnings
    }
    if not valid then result.error = "nftables syntax check failed" end
    return result
end

local function read()
    local source = read_file(FIREWALL_SOURCE)
    if source == nil then return { ok = false, error = "cannot read " .. FIREWALL_SOURCE, path = FIREWALL_SOURCE } end
    local applied_source = read_file(APPLIED_SOURCE)
    local runtime_tables = managed_tables()
    local active, found, missing, count = active_firewall(runtime_tables, applied_source, true)
    return {
        ok = true, config = source, path = FIREWALL_SOURCE, bytes = #source,
        active = active, active_found = found, missing_tables = missing,
        table_count = #runtime_tables, active_table_count = count,
        applied = applied_source ~= nil, applied_config = applied_source or "",
        candidate_config = read_file(CANDIDATE) or "", applied_path = APPLIED_SOURCE, candidate_path = CANDIDATE
    }
end

local function save(raw)
    local checked = validate(raw)
    if not checked.valid then checked.compiled = nil; return checked end
    local saved, save_error = write_atomic(FIREWALL_SOURCE, checked.config, 600)
    if not saved then return { ok = false, error = save_error } end
    return {
        ok = true, valid = true, path = FIREWALL_SOURCE, config = checked.config,
        bytes = #checked.config, warnings = checked.warnings
    }
end

local function apply(raw, write_candidate)
    local source = normalize(raw)
    if write_candidate then
        local saved, save_error = write_atomic(CANDIDATE, source, 600)
        if not saved then return { ok = false, error = save_error } end
    end
    local checked = validate(source)
    if not checked.valid then checked.compiled = nil; return checked end
    local desired, desired_tables = checked.compiled, checked.tables
    local previous_source, previous_compiled = read_file(APPLIED_SOURCE), read_file(APPLIED_COMPILED)
    local current_tables = managed_tables()
    local current = previous_compiled
    if current == nil and #current_tables > 0 then current = select(1, active_firewall(current_tables, nil, false)) end

    local applied, apply_error = run_transaction(transaction(current_tables, desired, desired_tables))
    if not applied then return { ok = false, valid = false, error = "failed to load configured nftables tables", detail = apply_error } end

    local runtime_tables = managed_tables()
    local verified = #runtime_tables == #desired_tables
    if verified then
        for _, spec in ipairs(desired_tables) do if not table_active(spec) then verified = false; break end end
    end
    if not verified then
        local restored, restore_error = run_transaction(transaction(runtime_tables, current or "", current_tables))
        local detail = "runtime table verification failed"
        if not restored then detail = detail .. "; nft rollback failed: " .. (restore_error or "unknown error") end
        return { ok = false, valid = false, error = "configured firewall transaction failed verification", detail = detail }
    end

    local compiled_saved, compiled_error = write_atomic(APPLIED_COMPILED, desired, 600)
    local source_saved, source_error = false, nil
    if compiled_saved then source_saved, source_error = write_atomic(APPLIED_SOURCE, checked.config, 600) end
    if not compiled_saved or not source_saved then
        local restored, restore_error = run_transaction(transaction(runtime_tables, current or "", current_tables))
        restore_file(APPLIED_COMPILED, previous_compiled)
        restore_file(APPLIED_SOURCE, previous_source)
        local detail = compiled_error or source_error or "cannot save applied firewall snapshot"
        if not restored then detail = detail .. "; nft rollback failed: " .. (restore_error or "unknown error") end
        return { ok = false, valid = false, error = detail }
    end

    local active, found, missing, count = active_firewall(runtime_tables, checked.config, true)
    return {
        ok = true, applied = true, config = checked.config, applied_config = checked.config,
        active = active, active_found = found, missing_tables = missing,
        table_count = #runtime_tables, active_table_count = count, warnings = checked.warnings
    }
end

local function remove()
    local current_tables = managed_tables()
    local removed, remove_error = run_transaction(transaction(current_tables, "", {}))
    if not removed then return { ok = false, error = "failed to remove configured nftables tables", detail = remove_error } end
    if #managed_tables() > 0 then return { ok = false, error = "some NftFlow nftables tables are still active" } end
    os.remove(CANDIDATE); os.remove(APPLIED_SOURCE); os.remove(APPLIED_COMPILED)
    return { ok = true, enabled = false, active = "# No active NftFlow nftables objects were found.\n" }
end

local function read_rpc_input(path)
    path = tostring(path or "")
    if not path:match("^/var/run/nftflow/rpc%-[A-Za-z0-9]+/payload$") then return nil, "invalid internal RPC input path" end
    local raw = read_file(path)
    if raw == nil then return nil, "cannot read internal RPC input file" end
    return raw
end

local function dispatch(command, args)
    if command == "firewall" then
        local mode = args[1] or "on"
        if mode == "off" then return remove() end
        if mode ~= "on" then return { ok = false, error = "firewall mode must be on or off" } end
        local source = read_file(FIREWALL_SOURCE)
        if source == nil then return { ok = false, error = "cannot read " .. FIREWALL_SOURCE } end
        return apply(source, false)
    elseif command == "firewall-read" then return read()
    elseif command == "firewall-validate" then
        local result = validate(args[1]); result.compiled = nil; return result
    elseif command == "firewall-save" then return save(args[1])
    elseif command == "firewall-apply" then return apply(args[1], true)
    elseif command == "firewall-validate-file" or command == "firewall-save-file" or command == "firewall-apply-file" then
        local raw, read_error = read_rpc_input(args[1])
        if raw == nil then return { ok = false, valid = false, error = read_error } end
        if command == "firewall-validate-file" then local result = validate(raw); result.compiled = nil; return result end
        if command == "firewall-save-file" then return save(raw) end
        return apply(raw, true)
    end
    return { ok = false, error = "unsupported firewall command: " .. tostring(command) }
end

local command, args = arg[1] or "", {}
for index = 2, #arg do args[#args + 1] = arg[index] end
local ok, result = pcall(dispatch, command, args)
local code = 0
if not ok then result, code = { ok = false, error = tostring(result) }, 1
elseif type(result) ~= "table" then result = { ok = true, result = result }
elseif result.ok == false then code = 1 end
io.write(json_encode(result) .. "\n")
os.exit(code)