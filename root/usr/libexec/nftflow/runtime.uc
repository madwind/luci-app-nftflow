#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0
// NftFlow process/runtime controller implemented in native OpenWrt ucode.

'use strict';

import * as fs from 'fs';

const RUNTIME = '/var/run/nftflow';
const PID_FILE = `${RUNTIME}/xray.pid`;
const STATE_FILE = `${RUNTIME}/state.json`;
const APPLIED_CONFIG = `${RUNTIME}/config.applied.yaml`;
const FIREWALL_CTL = '/usr/libexec/nftflow/firewall.uc';
const ROUTING_CTL = '/usr/libexec/nftflow/routing.uc';
const UPDATE_CTL = '/usr/libexec/nftflow/update.uc';
const STATES = { starting: true, ready: true, stopping: true, stopped: true, failed: true };
let sequence = 0;

function q(value) { return `'${replace(`${value ?? ''}`, /'/g, `'\\''`)}'`; }
function capture(command) {
    let proc = fs.popen(`${command} 2>&1`, 'r');
    if (!proc) return { ok: false, output: 'unable to execute command' };
    let output = proc.read('all') || '';
    let rc = proc.close();
    return { ok: rc === 0, output };
}
function quiet(command) { return system(`${command} >/dev/null 2>&1`) === 0; }
function mkdirp(path) { return quiet(`mkdir -p ${q(path)}`); }
function read_text(path) { return fs.readfile(path); }
function pid_self() { let p = fs.popen('echo $PPID', 'r'); if (!p) return 0; let n = int(trim(p.read('all') || '0')); p.close(); return n; }
function atomic_write(path, value, mode) {
    let parent = fs.dirname(path) || '.';
    if (!mkdirp(parent)) return { ok: false, error: `cannot create ${parent}` };
    sequence++;
    let temporary = `${path}.tmp.${pid_self()}.${time()}.${sequence}`;
    let written = fs.writefile(temporary, value);
    if (written == null || written != length(value)) { fs.unlink(temporary); return { ok: false, error: `cannot write temporary file for ${path}` }; }
    if (mode != null) fs.chmod(temporary, mode);
    if (fs.rename(temporary, path) !== true) { fs.unlink(temporary); return { ok: false, error: `cannot replace ${path}` }; }
    if (mode != null) fs.chmod(path, mode);
    return { ok: true };
}
function uci_get(option, fallback) {
    let result = capture(`/sbin/uci -q get nftflow.main.${option}`);
    let value = trim(result.output || '');
    return result.ok && value ? value : fallback;
}
function bool(value) { return value === true || value === 1 || value == '1' || value == 'true' || value == 'yes' || value == 'on'; }
function main_config() {
    let gid = int(uci_get('run_gid', '23333'));
    if (!gid || gid < 1 || gid > 65535) die('run_gid must be between 1 and 65535');
    let nofile = int(uci_get('nofile', '65536')) || 65536;
    if (nofile < 1024) die('nofile must be at least 1024');
    return {
        enabled: bool(uci_get('enabled', '0')),
        xray_bin: uci_get('xray_bin', '/usr/bin/xray'),
        config_file: uci_get('config_file', '/etc/nftflow/config.yaml'),
        asset_dir: uci_get('asset_dir', '/usr/share/xray'),
        run_gid: gid,
        run_group: uci_get('run_group', 'nftflow'),
        nofile
    };
}
function parse_json(raw) { try { return json(raw); } catch (e) { return null; } }
function read_state() {
    let state = parse_json(read_text(STATE_FILE) || '');
    return type(state) == 'object' ? state : null;
}
function write_state(state, process_pid, message) {
    if (!STATES[state]) return { ok: false, error: `invalid runtime state: ${state}` };
    if (process_pid != null && !trim(`${process_pid}`)) process_pid = null;
    if (process_pid != null) {
        process_pid = int(process_pid);
        if (!process_pid || process_pid < 2) return { ok: false, error: 'invalid runtime PID' };
    }
    if (!mkdirp(RUNTIME)) return { ok: false, error: `cannot create ${RUNTIME}` };

    let previous = read_state() || {};
    let now = time();
    let result = { state, updated: now, restart_count: int(previous.restart_count || 0) };
    if (state == 'starting') {
        result.pid = process_pid;
        result.started = now;
        if (previous.state == 'failed' || previous.state == 'ready' || previous.state == 'starting') result.restart_count++;
    } else if (state == 'ready' || state == 'stopping') {
        result.pid = process_pid || int(previous.pid || 0) || null;
        result.started = int(previous.started || 0) || null;
    } else if (state == 'failed') {
        result.pid = process_pid;
        result.started = int(previous.started || 0) || null;
        result.finished = now;
    } else {
        result.finished = now;
    }
    if (message != null && `${message}`) result.error = `${message}`;

    if ((state == 'starting' || state == 'ready' || state == 'stopping') && result.pid) {
        let saved = atomic_write(PID_FILE, `${result.pid}\n`, 0o600);
        if (!saved.ok) return saved;
    } else {
        fs.unlink(PID_FILE);
    }
    let saved = atomic_write(STATE_FILE, sprintf('%J\n', result), 0o600);
    if (!saved.ok) return saved;
    return { ok: true, state: result };
}
function canonical(path) {
    let result = capture(`readlink -f ${q(path)}`);
    let value = trim(result.output || '');
    return result.ok && value ? value : path;
}
function process_pid(binary) {
    let process_pid = int(trim(read_text(PID_FILE) || '0'));
    if (!process_pid || process_pid < 2 || !quiet(`kill -0 ${process_pid}`)) return null;
    let actual = capture(`readlink -f /proc/${process_pid}/exe`);
    if (!actual.ok || trim(actual.output || '') != trim(canonical(binary))) return null;
    return process_pid;
}
function terminate(process_pid) {
    process_pid = int(process_pid || 0);
    if (process_pid < 2 || !quiet(`kill -0 ${process_pid}`)) return true;
    quiet(`kill -TERM ${process_pid}`);
    for (let i = 0; i < 5; i++) {
        if (!quiet(`kill -0 ${process_pid}`)) return true;
        quiet('sleep 1');
    }
    quiet(`kill -KILL ${process_pid}`);
    return !quiet(`kill -0 ${process_pid}`);
}
function parse_result(output) {
    let lines = split(trim(output || ''), /\r?\n/);
    for (let i = length(lines) - 1; i >= 0; i--) {
        if (!trim(lines[i])) continue;
        let parsed = parse_json(trim(lines[i]));
        if (type(parsed) == 'object') return parsed;
    }
    return null;
}
function run_ucode(path, args) {
    let command = `/usr/bin/ucode ${q(path)}`;
    for (let value in (args || [])) command += ` ${q(value)}`;
    let executed = capture(command);
    let result = parse_result(executed.output || '');
    return type(result) == 'object' ? result : { ok: false, error: executed.ok ? 'command returned invalid JSON' : trim(executed.output || 'command failed') };
}
function remove_temporary_files() {
    if (!mkdirp(RUNTIME)) return { ok: false, error: `cannot create ${RUNTIME}` };
    for (let pattern in [
        `${RUNTIME}/config-check*.yaml*`, `${RUNTIME}/firewall-check*.nft*`, `${RUNTIME}/firewall-apply*.nft*`,
        `${RUNTIME}/*.nftflow-result.*`, `${RUNTIME}/*.nftflow-download.*`, `${RUNTIME}/*.tmp.*`
    ]) quiet(`rm -f ${pattern}`);
    quiet(`find ${q(RUNTIME)} -maxdepth 1 -type d -name 'rpc-*' -exec rm -rf {} \\;`);
    return { ok: true };
}
function prepare() {
    mkdirp(RUNTIME); mkdirp('/etc/nftflow'); mkdirp('/var/log/nftflow');
    let main = main_config();
    if (!process_pid(main.xray_bin)) {
        remove_temporary_files();
        let state = read_state();
        if (state && (state.state == 'starting' || state.state == 'ready' || state.state == 'stopping'))
            write_state('failed', null, 'stale runtime state cleaned during prepare');
    }
    return { ok: true };
}
function service_sync() {
    let enabled = bool(uci_get('enabled', '0'));
    let action = enabled ? 'enable' : 'disable';
    let result = capture(`/etc/init.d/nftflow ${action}`);
    if (!result.ok) return { ok: false, enabled, action, error: trim(result.output || '') };
    let verified = quiet('/etc/init.d/nftflow enabled');
    if (verified != enabled) return { ok: false, enabled, action, error: 'service boot state did not match nftflow.main.enabled' };
    return { ok: true, enabled, action };
}
function firewall_active() {
    let listed = capture('nft list tables');
    if (!listed.ok) return false;
    for (let line in split(listed.output || '', '\n')) if (match(trim(line), /^table\s+\S+\s+nftflow$/)) return true;
    return false;
}
function routing_status() {
    let result = run_ucode(ROUTING_CTL, [ 'status' ]);
    return result.ok === true ? result : { active: false, ipv4: false, ipv6: false };
}
function process_identity(process_pid_value) {
    if (!process_pid_value) return { uid: null, gid: null };
    let status = read_text(`/proc/${process_pid_value}/status`) || '';
    let uid = match(status, /(^|\n)Uid:\s*(\d+)/);
    let gid = match(status, /(^|\n)Gid:\s*(\d+)/);
    return { uid: uid ? int(uid[2]) : null, gid: gid ? int(gid[2]) : null };
}
function procd_state() {
    let result = capture(`ubus -S call service list '{"name":"nftflow"}'`);
    let parsed = result.ok ? parse_json(result.output || '') : null;
    let service = parsed && parsed.nftflow;
    if (type(service) != 'object' || type(service.instances) != 'object') return { managed: false, running: false };
    for (let name, instance in service.instances)
        if (type(instance) == 'object' && (instance.running === true || instance.running === 1)) return { managed: true, running: true };
    return { managed: true, running: false };
}
function status() {
    let main = main_config();
    let current_pid = process_pid(main.xray_bin);
    let runtime = read_state() || {};
    let state = STATES[runtime.state] ? runtime.state : (current_pid ? 'starting' : 'stopped');
    if (current_pid && (state == 'failed' || state == 'stopped')) state = 'starting';
    if (!current_pid && (state == 'starting' || state == 'ready')) state = 'failed';
    if (!current_pid && state == 'stopping') state = 'stopped';
    let identity = process_identity(current_pid);
    let routing = routing_status();
    let config = read_text(main.config_file);
    let version = capture('apk list --installed luci-app-nftflow 2>/dev/null');
    let version_match = version.ok ? match(trim(version.output || ''), /^luci-app-nftflow-([^\s]+)/) : null;
    let procd = procd_state();
    let started = int(runtime.started || 0);
    return {
        ok: true,
        running: current_pid != null,
        process: current_pid != null,
        procd_managed: procd.managed,
        procd_running: procd.running,
        runtime_state: state,
        state_error: runtime.error,
        app_version: version_match ? version_match[1] : null,
        pid: current_pid,
        uid: identity.uid,
        gid: identity.gid,
        uid_ok: current_pid ? identity.uid == 0 : null,
        expected_gid: main.run_gid,
        gid_ok: current_pid ? identity.gid == main.run_gid : null,
        enabled: main.enabled,
        uptime: current_pid && started ? max(0, time() - started) : null,
        restart_count: int(runtime.restart_count || 0),
        config_file: main.config_file,
        config_bytes: config ? length(config) : 0,
        firewall_active: firewall_active(),
        route_active: routing.active === true,
        route_ipv6: routing.ipv6 === true
    };
}
function action(name) {
    if (name != 'start' && name != 'stop' && name != 'restart' && name != 'reload') return { ok: false, error: 'unsupported service action' };
    let force = name == 'start' || name == 'restart';
    let init_action = name == 'reload' ? 'restart' : name;
    let result = capture(`${force ? 'NFTFLOW_FORCE_START=1 ' : ''}/etc/init.d/nftflow ${q(init_action)}`);
    let current = status();
    if (!result.ok) return { ok: false, action: name, init_action, accepted: false, detail: trim(result.output || ''), status: current };
    return { ok: true, action: name, init_action, accepted: true, runtime_state: current.runtime_state, detail: trim(result.output || ''), status: current };
}
function cleanup() {
    let main = main_config();
    let current_pid = process_pid(main.xray_bin);
    if (current_pid && !terminate(current_pid)) return { ok: false, error: `cannot stop Xray process ${current_pid}` };
    for (let kind in [ 'nftflow', 'xray', 'geoip', 'geosite' ]) run_ucode(UPDATE_CTL, [ 'stop', kind ]);
    let firewall = run_ucode(FIREWALL_CTL, [ 'firewall', 'off' ]);
    if (firewall.ok === false) return firewall;
    let routing = run_ucode(ROUTING_CTL, [ 'route', 'del' ]);
    if (routing.ok === false) return routing;
    remove_temporary_files();
    fs.unlink(APPLIED_CONFIG); fs.unlink(STATE_FILE); fs.unlink(PID_FILE);
    return { ok: true, cleaned: true };
}
function dispatch(command, args) {
    if (command == 'prepare') return prepare();
    if (command == 'service-sync') return service_sync();
    if (command == 'cleanup') return cleanup();
    if (command == 'state') return write_state(args[0] || '', args[1], args[2]);
    if (command == 'status') return status();
    if (command == 'reload') return action('reload');
    if (command == 'action') return action(args[0]);
    return { ok: false, error: `unsupported runtime command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
