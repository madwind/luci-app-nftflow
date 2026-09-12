#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0

'use strict';

import { access, chmod, mkdtemp, mkdir, open, rmdir, unlink } from 'fs';
import { cursor } from 'uci';

let ubus = require('ubus').connect();

const RUNTIME = '/var/run/nftflow';
const CTL = '/usr/libexec/nftflow/nftflowctl';
const UPDATE = '/usr/libexec/nftflow/update.uc';
const SAVED_FIREWALL = '/etc/nftflow/firewall.nft';
const STATE_FILE = `${RUNTIME}/state.json`;
const RPC_DIRECTORY_MODE = 448;
const RPC_FILE_MODE = 384;

function parse_result(output) {
    let lines = split(trim(output || ''), /\r?\n/);
    for (let i = length(lines) - 1; i >= 0; i--) {
        let line = trim(lines[i] || '');
        if (!line) continue;
        try { let value = json(line); if (type(value) == 'object') return value; } catch (e) {}
    }
    return { ok: false, error: trim(output || '') || 'controller returned no JSON' };
}

function exec_result(code, reply, label) {
    if (code !== UBUS_STATUS_OK) return { ok: false, error: `${label} request failed with ubus status ${code}` };
    if (type(reply) != 'object') return { ok: false, error: `${label} returned no execution result` };
    let result = parse_result(`${reply.stdout || ''}`);
    let stderr = trim(`${reply.stderr || ''}`), exit_code = int(reply.code || 0);
    if (exit_code !== 0 && result.ok === true) return { ok: false, error: stderr || `${label} exited with status ${exit_code}` };
    if (result.ok === false && stderr && !result.detail) result.detail = stderr;
    return result;
}

function defer_exec(request, command, params, label, cleanup) {
    if (!ubus) {
        if (cleanup) cleanup();
        return { ok: false, error: 'unable to connect to ubus' };
    }
    try {
        return ubus.defer('file', 'exec', { command, params: params || [] }, function(code, reply) {
            let result;
            try { result = exec_result(code, reply, label); }
            catch (e) { result = { ok: false, error: `${label}: ${e}` }; }
            if (cleanup) cleanup();
            request.reply(result, UBUS_STATUS_OK);
        });
    } catch (e) {
        if (cleanup) cleanup();
        return { ok: false, error: `${label}: ${e}` };
    }
}

function read_text(path) {
    let file = open(path, 'r');
    if (!file) return null;
    let value = file.read('all') || '';
    file.close();
    return value;
}

function read_json(path) {
    let raw = read_text(path);
    if (raw == null || !trim(raw)) return null;
    try { let value = json(raw); return type(value) == 'object' ? value : null; } catch (e) { return null; }
}

function main_option(name, fallback) {
    let ctx = cursor(), value = null;
    try { value = ctx.get('nftflow', 'main', name); } catch (e) {}
    return value == null || `${value}` == '' ? fallback : `${value}`;
}
function service_enabled() {
    let value = main_option('enabled', '0');
    return value === true || value === 1 || value == '1';
}
function runtime_command() { return main_option('command', ''); }

function service_sync() {
    let enabled = service_enabled();
    let action = enabled ? 'enable' : 'disable';
    if (system(`/etc/init.d/nftflow ${action} >/dev/null 2>&1`) !== 0)
        return { ok: false, enabled, error: `Unable to ${action} NftFlow at boot.` };
    return { ok: true, enabled };
}

function service_running(name) {
    if (!ubus) return false;
    try {
        let result = ubus.call('service', 'list', { name }), service = result && result[name];
        if (type(service) != 'object' || type(service.instances) != 'object') return false;
        for (let instance_name, instance in service.instances)
            if (type(instance) == 'object' && (instance.running === true || instance.running === 1)) return true;
    } catch (e) {}
    return false;
}

function service_runtime() {
    let state = read_json(STATE_FILE) || {};
    let running = service_running('nftflow');
    let runtime_state = `${state.state || ''}`;
    let command = runtime_command();
    let available = !!command && substr(command, 0, 1) == '/' && access(command, 'x') === true;
    return {
        ok: true,
        running,
        runtime_available: available,
        runtime_command: command || null,
        ready: running && runtime_state == 'ready',
        busy: runtime_state == 'starting' || runtime_state == 'stopping',
        state: available ? (runtime_state || (running ? 'starting' : 'stopped')) : 'unavailable',
        error: runtime_state == 'failed' ? `${state.error || ''}` : null
    };
}

function firewall_read() {
    let config = read_text(SAVED_FIREWALL);
    return config == null ? { ok: false, error: `cannot read ${SAVED_FIREWALL}` } : { ok: true, config };
}

function create_payload(value) {
    let content = `${value == null ? '' : value}`;
    if (access(RUNTIME, 'f') !== true && mkdir(RUNTIME, RPC_DIRECTORY_MODE) !== true && access(RUNTIME, 'f') !== true) return null;
    let directory = mkdtemp(`${RUNTIME}/rpc-XXXXXX`);
    if (!directory) return null;
    let path = `${directory}/payload`, file = open(path, 'wx', RPC_FILE_MODE);
    if (!file) { rmdir(directory); return null; }
    let written = file.write(content), closed = file.close();
    if (written == null || written !== length(content) || closed !== true || chmod(path, RPC_FILE_MODE) !== true) {
        unlink(path); rmdir(directory); return null;
    }
    return { directory, path };
}

function remove_payload(payload) {
    if (!payload) return;
    if (payload.path) unlink(payload.path);
    if (payload.directory) rmdir(payload.directory);
}

function defer_ctl(request, args, label) { return defer_exec(request, CTL, args, label); }
function defer_update(request, command, value, label) {
    let params = [ UPDATE, command ];
    if (value != null) push(params, `${value}`);
    return defer_exec(request, '/usr/bin/ucode', params, label);
}
function defer_ctl_file(request, command, value, label) {
    let payload = create_payload(value);
    if (!payload) return { ok: false, error: 'unable to create secure RPC temporary file' };
    return defer_exec(request, CTL, [ command, payload.path ], label, function() { remove_payload(payload); });
}
function valid_action(name) { return name == 'start' || name == 'stop' || name == 'restart'; }
function request_args(request) { return request && request.args ? request.args : {}; }

const methods = {
    status: { args: {}, call: request => defer_ctl(request, [ 'status' ], 'NftFlow status') },
    service_runtime: { args: {}, call: () => service_runtime() },
    service_sync: { args: {}, call: () => service_sync() },
    firewall_read: { args: {}, call: () => firewall_read() },
    firewall_runtime: { args: {}, call: request => defer_ctl(request, [ 'firewall-runtime' ], 'Firewall runtime read') },
    firewall_action_status: { args: {}, call: request => defer_ctl(request, [ 'component-status', 'firewall' ], 'Firewall action status') },
    firewall_save: { args: { config: '' }, call: request => defer_ctl_file(request, 'firewall-save-file', request_args(request).config || '', 'Firewall save') },
    firewall_install: { args: {}, call: request => defer_ctl(request, [ 'component-start', 'firewall', 'install' ], 'Firewall install') },
    firewall_uninstall: { args: {}, call: request => defer_ctl(request, [ 'component-start', 'firewall', 'uninstall' ], 'Firewall uninstall') },
    routing_read: { args: {}, call: request => defer_ctl(request, [ 'routing-read' ], 'Routing read') },
    routing_runtime: { args: {}, call: request => defer_ctl(request, [ 'routing-runtime' ], 'Routing runtime read') },
    routing_save: { args: { config: '' }, call: request => defer_ctl_file(request, 'routing-save-file', request_args(request).config || '', 'Routing save') },
    routing_install: { args: {}, call: request => defer_ctl(request, [ 'component', 'routing', 'install' ], 'Routing install') },
    routing_uninstall: { args: {}, call: request => defer_ctl(request, [ 'component', 'routing', 'uninstall' ], 'Routing uninstall') },
    config_read: { args: {}, call: request => defer_ctl(request, [ 'config-read' ], 'Configuration read') },
    config_apply: { args: { config: '' }, call: request => defer_ctl_file(request, 'config-apply-file', request_args(request).config || '', 'Configuration save and apply') },
    update_status: { args: {}, call: request => defer_update(request, 'status', null, 'Update status') },
    update_check: { args: {}, call: request => defer_update(request, 'check', null, 'NftFlow update check') },
    update_install: { args: {}, call: request => defer_update(request, 'start', null, 'NftFlow update') },
    update_settings: { args: {}, call: request => defer_update(request, 'auto-status', null, 'Update settings') },
    update_set_check: { args: { enabled: 0 }, call: request => defer_update(request, 'auto-set-check', request_args(request).enabled ? 1 : 0, 'Automatic update setting') },
    update_set_auto: { args: { enabled: 0 }, call: request => defer_update(request, 'auto-set', request_args(request).enabled ? 1 : 0, 'NftFlow automatic update setting') },
    action: {
        args: { name: '' },
        call: request => {
            let name = request_args(request).name || '';
            return valid_action(name) ? defer_ctl(request, [ 'action', name ], `NftFlow ${name}`) : { ok: false, error: 'unsupported service action' };
        }
    }
};

return { 'luci.nftflow': methods };
