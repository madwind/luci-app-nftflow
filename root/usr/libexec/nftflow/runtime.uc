#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const SELF = '/usr/libexec/nftflow/runtime.uc';
const RUNTIME = '/var/run/nftflow';
const PID_FILE = `${RUNTIME}/runtime.pid`;
const STATE_FILE = `${RUNTIME}/state.json`;
const COMPONENT_JOB_DIR = `${RUNTIME}/jobs`;
const FIREWALL_APPLIED = `${RUNTIME}/firewall.applied.nft`;
const ROUTING_APPLIED = `${RUNTIME}/routing.applied.conf`;
const FIREWALL_CTL = '/usr/libexec/nftflow/firewall.uc';
const ROUTING_CTL = '/usr/libexec/nftflow/routing.uc';
const COMPONENTS = {
    firewall: { install: [ FIREWALL_CTL, 'firewall', 'on' ], uninstall: [ FIREWALL_CTL, 'firewall', 'off' ] },
    routing: { install: [ ROUTING_CTL, 'route-apply' ], uninstall: [ ROUTING_CTL, 'route', 'del' ] }
};
const STATES = { starting: true, ready: true, stopping: true, stopped: true, failed: true };
let sequence = 0;
let uci = cursor();

function q(value) { return `'${replace(`${value ?? ''}`, /'/g, `'\\''`)}'`; }
function capture(command) {
    let proc = fs.popen(`${command} 2>&1`, 'r');
    if (!proc) return { ok: false, output: 'unable to execute command' };
    let output = proc.read('all') || '';
    let rc = proc.close();
    return { ok: rc === true || rc === 0, output, code: rc === true || rc === 0 ? 0 : int(rc || 1) };
}
function quiet(command) { return system(`${command} >/dev/null 2>&1`) === 0; }
function mkdirp(path) { return quiet(`mkdir -p ${q(path)}`); }
function read_text(path) { return fs.readfile(path); }
function pid_self() {
    let proc = fs.popen('echo $PPID', 'r');
    if (!proc) return 0;
    let value = int(trim(proc.read('all') || '0'));
    proc.close();
    return value;
}
function process_alive(value) { value = int(value || 0); return value > 1 && quiet(`kill -0 ${value}`); }
function atomic_write(path, value, mode) {
    let parent = fs.dirname(path) || '.';
    if (!mkdirp(parent)) return { ok: false, error: `cannot create ${parent}` };
    sequence++;
    let temporary = `${path}.tmp.${pid_self()}.${time()}.${sequence}`;
    let written = fs.writefile(temporary, value);
    if (written == null || written != length(value)) {
        fs.unlink(temporary);
        return { ok: false, error: `cannot write temporary file for ${path}` };
    }
    if (mode != null && fs.chmod(temporary, mode) !== true) {
        fs.unlink(temporary);
        return { ok: false, error: `cannot chmod temporary file for ${path}` };
    }
    if (fs.rename(temporary, path) !== true) {
        fs.unlink(temporary);
        return { ok: false, error: `cannot replace ${path}` };
    }
    if (mode != null) fs.chmod(path, mode);
    return { ok: true };
}
function uci_get(option, fallback) {
    let value = null;
    try { value = uci.get('nftflow', 'main', option); } catch (e) {}
    return value == null || `${value}` == '' ? fallback : `${value}`;
}
function bool(value) { return value === true || value === 1 || value == '1' || value == 'true' || value == 'yes' || value == 'on'; }
function main_config() {
    let gid = int(uci_get('run_gid', '23333'));
    if (!gid || gid < 1 || gid > 65535) die('run_gid must be between 1 and 65535');
    return {
        enabled: bool(uci_get('enabled', '0')),
        command: uci_get('command', ''),
        run_gid: gid
    };
}
function runtime_available(main) {
    main = main || main_config();
    return !!main.command && substr(main.command, 0, 1) == '/' && fs.access(main.command, 'x') === true;
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
    let result = { state, updated: now };
    if (state == 'starting') {
        result.pid = process_pid;
        result.started = now;
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
    return saved.ok ? { ok: true, state: result } : saved;
}
function canonical(path) {
    let result = capture(`readlink -f ${q(path)}`);
    let value = trim(result.output || '');
    return result.ok && value ? value : path;
}
function process_pid(binary) {
    if (!binary) return null;
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
        let line = trim(lines[i] || '');
        if (!line) continue;
        let parsed = parse_json(line);
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
    for (let pattern in [ `${RUNTIME}/firewall-check*.nft*`, `${RUNTIME}/firewall-apply*.nft*`, `${RUNTIME}/*.tmp.*` ])
        quiet(`rm -f ${pattern}`);
    quiet(`find ${q(RUNTIME)} -maxdepth 1 -type d -name 'rpc-*' -exec rm -rf {} \\;`);
    return { ok: true };
}
function prepare() {
    mkdirp(RUNTIME);
    mkdirp('/etc/nftflow');
    let main = main_config();
    if (!process_pid(main.command)) {
        remove_temporary_files();
        let state = read_state();
        if (state && (state.state == 'starting' || state.state == 'ready' || state.state == 'stopping'))
            write_state('failed', null, 'stale runtime state cleaned during prepare');
    }
    return { ok: true };
}
function firewall_active() { return read_text(FIREWALL_APPLIED) != null; }
function routing_status() {
    let raw = read_text(ROUTING_APPLIED);
    if (raw == null) return { active: false, ipv6: false };
    let ipv6 = false;
    for (let line in split(raw, '\n')) {
        line = trim(line || '');
        if (match(line, /^ip\s+-6\s+/)) { ipv6 = true; break; }
    }
    return { active: true, ipv6 };
}
function lightweight_status(main) {
    main = main || main_config();
    let current_pid = process_pid(main.command);
    let runtime = read_state() || {};
    let state = STATES[runtime.state] ? runtime.state : (current_pid ? 'starting' : 'stopped');
    if (current_pid && (state == 'failed' || state == 'stopped')) state = 'starting';
    if (!current_pid && (state == 'starting' || state == 'ready')) state = 'failed';
    if (!current_pid && state == 'stopping') state = 'stopped';
    return { running: current_pid != null, runtime_state: state, pid: current_pid };
}
function status() {
    let main = main_config();
    let available = runtime_available(main);
    let current = lightweight_status(main);
    let runtime = read_state() || {};
    let routing = routing_status();
    let started = int(runtime.started || 0);
    return {
        ok: true,
        running: available ? current.running : null,
        runtime_available: available,
        runtime_command: main.command || null,
        runtime_state: available ? current.runtime_state : 'unavailable',
        runtime_error: current.runtime_state == 'failed' ? `${runtime.error || ''}` : null,
        pid: current.pid,
        uptime: current.pid && started ? max(0, time() - started) : null,
        firewall_active: firewall_active(),
        route_active: routing.active === true,
        route_ipv6: routing.ipv6 === true
    };
}
function action_worker(name) {
    let result = capture(`/etc/init.d/nftflow ${q(name)}`);
    let detail = trim(result.output || '');
    if (!result.ok && (name == 'start' || name == 'restart'))
        write_state('failed', null, detail || `NftFlow ${name} failed`);
    return result.ok
        ? { ok: true, action: name, completed: true, detail }
        : { ok: false, action: name, completed: false, error: detail || `NftFlow ${name} failed` };
}
function action(name) {
    if (name != 'start' && name != 'stop' && name != 'restart') return { ok: false, error: 'unsupported service action' };
    let main = main_config();
    let before = lightweight_status(main);
    if (before.runtime_state == 'starting' || before.runtime_state == 'stopping')
        return { ok: false, action: name, accepted: false, runtime_state: before.runtime_state, error: 'another service action is already in progress' };
    if ((name == 'start' || name == 'restart') && !main.enabled)
        return { ok: false, action: name, accepted: false, runtime_state: before.runtime_state, error: 'NftFlow is disabled. Enable it in Settings first.' };
    if ((name == 'start' || name == 'restart') && !runtime_available(main))
        return { ok: false, action: name, accepted: false, runtime_state: 'unavailable', error: 'Runtime executable is not configured or is not executable.' };
    if (name == 'restart' && !before.running)
        return { ok: false, action: name, accepted: false, runtime_state: before.runtime_state, error: 'NftFlow is stopped. Use Start to start the service.' };
    if (!mkdirp(RUNTIME)) return { ok: false, action: name, accepted: false, error: `cannot create ${RUNTIME}` };

    let log = `${RUNTIME}/action-${name}.log`;
    let spawned = capture(`/usr/bin/ucode ${q(SELF)} action-worker ${q(name)} </dev/null >${q(log)} 2>&1 & echo $!`);
    let worker_pid = int(trim(spawned.output || '0'));
    if (!spawned.ok || worker_pid < 2) {
        if (name == 'start' || name == 'restart') write_state('failed', null, 'unable to start service action worker');
        return { ok: false, action: name, accepted: false, error: 'unable to start service action worker' };
    }
    return { ok: true, action: name, accepted: true, worker_pid, runtime_state: before.runtime_state, running: before.running };
}
function component(kind, operation) {
    let spec = COMPONENTS[kind];
    if (!spec || (operation != 'install' && operation != 'uninstall'))
        return { ok: false, error: 'unsupported component action' };
    let command = operation == 'install' ? spec.install : spec.uninstall;
    return run_ucode(command[0], slice(command, 1));
}
function component_job_path(kind) { return `${COMPONENT_JOB_DIR}/${kind}.json`; }
function read_component_job(kind) {
    let state = parse_json(read_text(component_job_path(kind)) || '');
    return type(state) == 'object' ? state : null;
}
function save_component_job(kind, state) {
    if (!mkdirp(COMPONENT_JOB_DIR)) return false;
    return atomic_write(component_job_path(kind), sprintf('%J\n', state), 0o600).ok === true;
}
function component_worker(kind, operation, started) {
    started = int(started || 0);
    let result = component(kind, operation);
    let current = read_component_job(kind) || {};
    if (int(current.started || 0) == started && `${current.operation || ''}` == operation) {
        save_component_job(kind, {
            kind,
            operation,
            status: result.ok === true ? 'done' : 'failed',
            started,
            finished: time(),
            pid: null,
            result
        });
    }
    return result;
}
function component_start(kind, operation) {
    let spec = COMPONENTS[kind];
    if (!spec || (operation != 'install' && operation != 'uninstall'))
        return { ok: false, error: 'unsupported component action' };

    let current = read_component_job(kind) || {};
    if ((current.status == 'starting' || current.status == 'running') && process_alive(current.pid))
        return { ok: false, error: `${kind} action is already running`, state: current };

    let started = time();
    if (!save_component_job(kind, { kind, operation, status: 'starting', started, pid: null }))
        return { ok: false, error: `cannot save ${kind} action state` };

    let log = `${RUNTIME}/${kind}-${operation}.log`;
    let spawned = capture(`/usr/bin/ucode ${q(SELF)} component-worker ${q(kind)} ${q(operation)} ${started} </dev/null >${q(log)} 2>&1 & echo $!`);
    let worker_pid = int(trim(spawned.output || '0'));
    if (!spawned.ok || worker_pid < 2) {
        let failed = { kind, operation, status: 'failed', started, finished: time(), pid: null, result: { ok: false, error: `unable to start ${kind} action worker` } };
        save_component_job(kind, failed);
        return { ok: false, error: failed.result.error, state: failed };
    }

    current = read_component_job(kind) || {};
    if (int(current.started || 0) == started && current.status == 'starting') {
        current.status = 'running';
        current.pid = worker_pid;
        save_component_job(kind, current);
    }
    return { ok: true, accepted: true, kind, operation, started, pid: worker_pid };
}
function component_status(kind) {
    if (!COMPONENTS[kind]) return { ok: false, error: 'unsupported component action' };
    let state = read_component_job(kind);
    if (!state) return { ok: true, kind, status: 'idle' };
    if ((state.status == 'starting' || state.status == 'running') && state.pid && !process_alive(state.pid)) {
        state.status = 'failed';
        state.finished = time();
        state.pid = null;
        state.result = { ok: false, error: `${kind} action worker exited unexpectedly` };
        save_component_job(kind, state);
    }
    state.ok = true;
    return state;
}
function cleanup_rules() {
    let errors = [];
    let firewall = component('firewall', 'uninstall');
    if (firewall.ok !== true) push(errors, `firewall cleanup failed: ${firewall.detail || firewall.error || 'unknown error'}`);
    let routing = component('routing', 'uninstall');
    if (routing.ok !== true) push(errors, `routing cleanup failed: ${routing.detail || routing.error || 'unknown error'}`);
    return length(errors) ? { ok: false, cleaned: false, error: join('; ', errors) } : { ok: true, cleaned: true };
}
function bootstrap_rules() {
    let stale = cleanup_rules();
    if (stale.ok !== true)
        return { ok: false, firewall_active: false, route_active: false, error: `rule cleanup before bootstrap failed: ${stale.error || 'unknown error'}` };

    let routing = component('routing', 'install');
    if (routing.ok !== true)
        return { ok: false, firewall_active: false, route_active: false, error: `routing installation failed: ${routing.detail || routing.error || 'unable to install policy routing'}` };

    let firewall = component('firewall', 'install');
    if (firewall.ok !== true) {
        let rollback = component('routing', 'uninstall');
        return {
            ok: false,
            firewall_active: false,
            route_active: false,
            error: `firewall installation failed: ${firewall.detail || firewall.error || 'unable to load nftables rules'}`,
            detail: rollback.ok === true ? null : `routing rollback failed: ${rollback.detail || rollback.error || 'unknown error'}`
        };
    }

    return { ok: true, firewall_active: true, route_active: true };
}
function cleanup() {
    let errors = [];
    let main = main_config();
    let current_pid = process_pid(main.command);
    if (current_pid && !terminate(current_pid)) push(errors, `cannot stop runtime process ${current_pid}`);

    let rules = cleanup_rules();
    if (rules.ok === false) push(errors, rules.error || 'rule cleanup failed');
    let temporary = remove_temporary_files();
    if (temporary.ok === false) push(errors, temporary.error || 'temporary file cleanup failed');
    fs.unlink(STATE_FILE);
    fs.unlink(PID_FILE);

    return length(errors) ? { ok: false, cleaned: false, error: join('; ', errors) } : { ok: true, cleaned: true };
}
function dispatch(command, args) {
    if (command == 'prepare') return prepare();
    if (command == 'cleanup') return cleanup();
    if (command == 'bootstrap-rules') return bootstrap_rules();
    if (command == 'cleanup-rules') return cleanup_rules();
    if (command == 'state') return write_state(args[0] || '', args[1], args[2]);
    if (command == 'status') return status();
    if (command == 'action') return action(args[0]);
    if (command == 'action-worker') return action_worker(args[0]);
    if (command == 'component') return component(args[0], args[1]);
    if (command == 'component-start') return component_start(args[0], args[1]);
    if (command == 'component-status') return component_status(args[0]);
    if (command == 'component-worker') return component_worker(args[0], args[1], args[2]);
    return { ok: false, error: `unsupported runtime command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
