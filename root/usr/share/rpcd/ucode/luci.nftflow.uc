#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0
// ACL-protected bridge between LuCI and the current NftFlow subsystem controllers.

'use strict';

import { access, chmod, mkdtemp, mkdir, open, popen, rmdir, unlink } from 'fs';

const RUNTIME = '/var/run/nftflow';
const CTL = '/usr/libexec/nftflow/nftflowctl';
const GEO_UPDATE = '/usr/libexec/nftflow/geo-update.lua';
const SOFTWARE_UPDATE = '/usr/libexec/nftflow/update.lua';
const STOP_UPDATE = '/usr/libexec/nftflow/stop-update.lua';
const GEO_CRON_TAG = 'nftflow-geodata-weekly';
const RPC_DIRECTORY_MODE = 448;
const RPC_FILE_MODE = 384;
const RPC_PAYLOAD_MAX_BYTES = 32 * 1024;
const SAVED_CONFIG = '/etc/nftflow/config.yaml';
const SAVED_FIREWALL = '/etc/nftflow/firewall.nft';
const SAVED_ROUTING = '/etc/nftflow/routing.conf';
const DEFAULT_CONFIG = '/usr/share/nftflow/defaults/config.yaml';
const DEFAULT_FIREWALL = '/usr/share/nftflow/defaults/firewall.nft';
const DEFAULT_ROUTING = '/usr/share/nftflow/defaults/routing.conf';
const APPLIED_CONFIG = RUNTIME + '/config.applied.yaml';
const APPLIED_FIREWALL = RUNTIME + '/firewall.applied.nft';
const CANDIDATE_FIREWALL = RUNTIME + '/firewall.candidate.nft';
const APPLIED_ROUTING = RUNTIME + '/routing.applied.conf';
const CANDIDATE_ROUTING = RUNTIME + '/routing.candidate.conf';

function parse_result(output) {
    let lines = split(trim(output || ''), /\r?\n/);
    for (let i = length(lines) - 1; i >= 0; i--) {
        if (!trim(lines[i])) continue;
        try { return json(trim(lines[i])); } catch (e) {}
    }
    return { ok: false, error: trim(output || 'nftflowctl returned no JSON') };
}

function shellquote(value) { return "'" + replace(`${value == null ? '' : value}`, /'/g, "'\\''") + "'"; }
function run_command(command) {
    let fd = popen(`${command} 2>&1`, 'r');
    if (!fd) return { ok: false, error: 'unable to execute command' };
    let output = fd.read('all') || '';
    let success = fd.close();
    let result = parse_result(output);
    if (success !== true && success !== 0 && result.ok === true) { result.ok = false; result.error = `command exited with an error: ${trim(output)}`; }
    return result;
}
function capture_command(command) {
    let fd = popen(`${command} 2>&1`, 'r');
    if (!fd) return { ok: false, output: '', error: 'unable to execute command' };
    let output = fd.read('all') || '';
    let success = fd.close();
    let ok = success === true || success === 0;
    return { ok: ok, output: output, error: ok ? null : (trim(output) || 'command failed') };
}
function read_text(path) { let file = open(path, 'r'); if (!file) return null; let value = file.read('all') || ''; file.close(); return value; }
function run_ctl(args) { let command = `/bin/sh ${CTL}`; for (let arg in args) command += ` ${shellquote(arg)}`; return run_command(command); }
function run_geo_update(command, kind) { let line = `/usr/bin/lua ${GEO_UPDATE} ${shellquote(command)}`; if (kind) line += ` ${shellquote(kind)}`; return run_command(line); }
function run_software_update(command, kind) { let line = `/usr/bin/lua ${SOFTWARE_UPDATE} ${shellquote(command)}`; if (kind) line += ` ${shellquote(kind)}`; return run_command(line); }
function run_stop_update(kind) { return run_command(`/usr/bin/lua ${STOP_UPDATE} ${shellquote(kind)}`); }

function config_read_effective() {
    let result = run_ctl([ 'config-read' ]);
    if (result && result.ok === true) return result;
    let config = read_text(DEFAULT_CONFIG);
    if (config == null) return result;
    return { ok: true, config: config, path: SAVED_CONFIG, bytes: length(config), using_default: true, applied: read_text(APPLIED_CONFIG) != null, applied_path: APPLIED_CONFIG };
}

function firewall_read_effective() {
    let result = run_ctl([ 'firewall-read' ]);
    if (result && result.ok === true) return result;
    let config = read_text(DEFAULT_FIREWALL);
    if (config == null) return result;
    let runtime = capture_command('nft list table inet nftflow');
    let active = runtime.ok && trim(runtime.output || '') ? runtime.output : '# No managed NftFlow nftables tables were found.\n';
    let applied = read_text(APPLIED_FIREWALL);
    return {
        ok: true, config: config, path: SAVED_FIREWALL, bytes: length(config), using_default: true,
        active: active, active_found: runtime.ok === true && trim(runtime.output || '') !== '',
        table_count: runtime.ok === true ? 1 : 0, active_table_count: runtime.ok === true ? 1 : 0, missing_tables: [],
        applied: applied != null, applied_config: applied || '', candidate_config: read_text(CANDIDATE_FIREWALL) || '',
        applied_path: APPLIED_FIREWALL, candidate_path: CANDIDATE_FIREWALL
    };
}

function routing_runtime_text(table_id, ipv6) {
    let rule4 = capture_command('ip -4 rule show');
    let route4 = capture_command(`ip -4 route show table ${table_id}`);
    let output = '# ip -4 rule show\n' + (rule4.ok ? trim(rule4.output) : '(unavailable)') + `\n\n# ip -4 route show table ${table_id}\n` + (route4.ok ? trim(route4.output) : '(unavailable)');
    if (ipv6) {
        let rule6 = capture_command('ip -6 rule show');
        let route6 = capture_command(`ip -6 route show table ${table_id}`);
        output += '\n\n# ip -6 rule show\n' + (rule6.ok ? trim(rule6.output) : '(unavailable)') + `\n\n# ip -6 route show table ${table_id}\n` + (route6.ok ? trim(route6.output) : '(unavailable)');
    }
    return output + '\n';
}

function routing_read_effective() {
    let result = run_ctl([ 'routing-read' ]);
    if (result && result.ok === true) return result;
    let config = read_text(DEFAULT_ROUTING);
    if (config == null) return result;
    let checked = run_ctl([ 'routing-validate', config ]);
    if (!checked || checked.ok !== true) return result;
    let status = run_ctl([ 'status' ]);
    let table_id = checked.routing_table || 100;
    let applied = read_text(APPLIED_ROUTING);
    return {
        ok: true, path: SAVED_ROUTING, config: checked.config || config, bytes: length(checked.config || config), using_default: true,
        commands: checked.commands || [], route_commands: checked.route_commands || [], rule_commands: checked.rule_commands || [],
        active: routing_runtime_text(table_id, checked.ipv6_enabled === true),
        route_active: status && status.ok === true && status.route_active === true,
        route_ipv4: status && status.ok === true && status.route_active === true,
        route_ipv6: status && status.ok === true && status.route_ipv6 === true,
        ipv6_enabled: checked.ipv6_enabled === true, firewall_mark: checked.firewall_mark, routing_table: table_id,
        applied_config: applied || '', applied_path: APPLIED_ROUTING, candidate_path: CANDIDATE_ROUTING
    };
}

function status_with_defaults() {
    let result = run_ctl([ 'status' ]);
    if (!result || result.ok !== true) return result;
    if (read_text(SAVED_ROUTING) == null) {
        let routing = read_text(DEFAULT_ROUTING);
        if (routing != null) {
            let checked = run_ctl([ 'routing-validate', routing ]);
            if (checked && checked.ok === true) { result.routing_configured = true; result.policy_route_commands = checked.commands || []; result.routing_default = true; }
        }
    }
    return result;
}

function weekly_geo_status() {
    let result = run_ctl([ 'geo', 'status' ]);
    if (!result || result.ok !== true) return result;
    let scheduled = false;
    let fd = open('/etc/crontabs/root', 'r');
    if (fd) { let crontab = fd.read('all') || ''; fd.close(); scheduled = index(crontab, GEO_CRON_TAG) >= 0; }
    let schedule = scheduled ? run_geo_update('next-run') : null;
    result.auto_update = { scheduled: scheduled, interval_days: 7, schedule: '17 4 * * 0', next_update: schedule && schedule.ok === true ? schedule.next_update : null };
    return result;
}

function create_payload(value) {
    let content = `${value == null ? '' : value}`;
    if (access(RUNTIME, 'f') !== true && mkdir(RUNTIME, RPC_DIRECTORY_MODE) !== true && access(RUNTIME, 'f') !== true) return null;
    let directory = mkdtemp(`${RUNTIME}/rpc-XXXXXX`); if (!directory) return null;
    let path = `${directory}/payload`; let file = open(path, 'wx', RPC_FILE_MODE);
    if (!file) { rmdir(directory); return null; }
    let written = file.write(content); let closed = file.close();
    if (written == null || written !== length(content) || closed !== true || chmod(path, RPC_FILE_MODE) !== true) { unlink(path); rmdir(directory); return null; }
    return { directory: directory, path: path };
}
function remove_payload(payload) { if (!payload) return; if (payload.path) unlink(payload.path); if (payload.directory) rmdir(payload.directory); }
function run_ctl_file(command, value) {
    value = `${value == null ? '' : value}`;
    if (length(value) > RPC_PAYLOAD_MAX_BYTES) return { ok: false, error: 'editor content is larger than 32 KiB' };
    let payload = create_payload(value); if (!payload) return { ok: false, error: 'unable to create secure RPC temporary file' };
    let result; try { result = run_ctl([ command, payload.path ]); } catch (e) { result = { ok: false, error: `${e}` }; }
    remove_payload(payload); return result;
}

function valid_action(name) { return name == 'start' || name == 'stop' || name == 'reload' || name == 'restart'; }
function valid_kind(kind) { return kind == 'geoip' || kind == 'geosite'; }
function valid_update_kind(kind) { return kind == 'nftflow' || kind == 'xray'; }

const methods = {
    status: { args: {}, call: () => status_with_defaults() },
    firewall_read: { args: {}, call: () => firewall_read_effective() },
    firewall_validate: { args: { config: '' }, call: request => run_ctl_file('firewall-validate-file', request && request.args ? request.args.config || '' : '') },
    firewall_save: { args: { config: '' }, call: request => run_ctl_file('firewall-save-file', request && request.args ? request.args.config || '' : '') },
    firewall_apply: { args: { config: '' }, call: request => run_ctl_file('firewall-apply-file', request && request.args ? request.args.config || '' : '') },
    routing_read: { args: {}, call: () => routing_read_effective() },
    routing_validate: { args: { config: '' }, call: request => run_ctl_file('routing-validate-file', request && request.args ? request.args.config || '' : '') },
    routing_save: { args: { config: '' }, call: request => run_ctl_file('routing-save-file', request && request.args ? request.args.config || '' : '') },
    routing_apply: { args: { config: '' }, call: request => run_ctl_file('routing-apply-file', request && request.args ? request.args.config || '' : '') },
    config_read: { args: {}, call: () => config_read_effective() },
    config_validate: { args: { config: '' }, call: request => run_ctl_file('config-validate-file', request && request.args ? request.args.config || '' : '') },
    config_apply: { args: { config: '' }, call: request => run_ctl_file('config-apply-file', request && request.args ? request.args.config || '' : '') },
    config_save: { args: { config: '' }, call: request => run_ctl_file('config-save-file', request && request.args ? request.args.config || '' : '') },
    geo_status: { args: {}, call: () => weekly_geo_status() },
    geo_stop: { args: { kind: 'geosite' }, call: request => { let kind = request && request.args ? request.args.kind || '' : ''; if (!valid_kind(kind)) return { ok: false, error: 'invalid geodata kind' }; return run_stop_update(kind); } },
    update_status: { args: {}, call: () => run_software_update('status') },
    update_install: { args: { kind: 'nftflow' }, call: request => { let kind = request && request.args ? request.args.kind || '' : ''; if (!valid_update_kind(kind)) return { ok: false, error: 'invalid update kind' }; return run_software_update('start', kind); } },
    update_stop: { args: { kind: 'nftflow' }, call: request => { let kind = request && request.args ? request.args.kind || '' : ''; if (!valid_update_kind(kind)) return { ok: false, error: 'invalid update kind' }; return run_stop_update(kind); } },
    action: { args: { name: '' }, call: request => { let name = request && request.args ? request.args.name || '' : ''; if (!valid_action(name)) return { ok: false, error: 'unsupported service action' }; return run_ctl([ 'action', name ]); } },
    service_sync: { args: {}, call: () => run_ctl([ 'service-sync' ]) }
};

return { 'luci.nftflow': methods };
