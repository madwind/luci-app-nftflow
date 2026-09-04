#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0
// ACL-protected, non-blocking bridge between LuCI and NftFlow controllers.

'use strict';

import { access, chmod, mkdtemp, mkdir, open, rmdir, unlink } from 'fs';

let ubus = require('ubus').connect();

const RUNTIME = '/var/run/nftflow';
const CTL = '/usr/libexec/nftflow/nftflowctl';
const UPDATE = '/usr/libexec/nftflow/update.uc';
const RPC_HELPER = '/usr/libexec/nftflow/rpc.uc';
const RPC_DIRECTORY_MODE = 448;
const RPC_FILE_MODE = 384;
const RPC_PAYLOAD_MAX_BYTES = 32 * 1024;
const SAVED_FIREWALL = '/etc/nftflow/firewall.nft';
const DEFAULT_FIREWALL = '/usr/share/nftflow/defaults/firewall.nft';
const APPLIED_FIREWALL = `${RUNTIME}/firewall.applied.nft`;
const CANDIDATE_FIREWALL = `${RUNTIME}/firewall.candidate.nft`;
const STATE_FILE = `${RUNTIME}/state.json`;

function parse_result(output) {
    let lines = split(trim(output || ''), /\r?\n/);
    for (let i = length(lines) - 1; i >= 0; i--) {
        let line = trim(lines[i] || '');
        if (!line) continue;
        try {
            let value = json(line);
            if (type(value) == 'object') return value;
        } catch (e) {}
    }
    return { ok: false, error: trim(output || '') || 'controller returned no JSON' };
}

function exec_result(code, reply, label) {
    if (code !== UBUS_STATUS_OK)
        return { ok: false, error: `${label} request failed with ubus status ${code}` };

    if (type(reply) != 'object')
        return { ok: false, error: `${label} returned no execution result` };

    let stdout = `${reply.stdout || ''}`;
    let stderr = trim(`${reply.stderr || ''}`);
    let exit_code = int(reply.code || 0);
    let result = parse_result(stdout);

    if (exit_code !== 0 && result.ok === true)
        return { ok: false, error: stderr || `${label} exited with status ${exit_code}` };

    if (result.ok === false && stderr && !result.detail)
        result.detail = stderr;

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
            try {
                result = exec_result(code, reply, label);
            } catch (e) {
                result = { ok: false, error: `${label}: ${e}` };
            }
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
    try {
        let value = json(raw);
        return type(value) == 'object' ? value : null;
    } catch (e) {
        return null;
    }
}

function service_running(name) {
    if (!ubus) return false;
    try {
        let result = ubus.call('service', 'list', { name });
        let service = result && result[name];
        if (type(service) != 'object' || type(service.instances) != 'object') return false;
        for (let instance_name, instance in service.instances)
            if (type(instance) == 'object' && (instance.running === true || instance.running === 1)) return true;
    } catch (e) {}
    return false;
}

function firewall_ready() {
    let state = read_json(STATE_FILE) || {};
    let running = service_running('nftflow');
    let runtime_state = `${state.state || ''}`;
    let ready = running && runtime_state == 'ready';
    let busy = runtime_state == 'starting' || runtime_state == 'stopping';
    return { ok: true, running, ready, busy, state: runtime_state || (running ? 'starting' : 'stopped') };
}

function firewall_read_effective() {
    let config = read_text(SAVED_FIREWALL), using_default = false;
    if (config == null) {
        config = read_text(DEFAULT_FIREWALL);
        using_default = true;
    }
    if (config == null)
        return { ok: false, error: `cannot read ${SAVED_FIREWALL} or ${DEFAULT_FIREWALL}`, path: SAVED_FIREWALL };

    let applied = read_text(APPLIED_FIREWALL);
    return {
        ok: true,
        config,
        path: SAVED_FIREWALL,
        bytes: length(config),
        using_default,
        applied: applied != null,
        applied_config: applied || '',
        candidate_config: read_text(CANDIDATE_FIREWALL) || '',
        applied_path: APPLIED_FIREWALL,
        candidate_path: CANDIDATE_FIREWALL
    };
}

function create_payload(value) {
    let content = `${value == null ? '' : value}`;
    if (length(content) > RPC_PAYLOAD_MAX_BYTES) return null;
    if (access(RUNTIME, 'f') !== true && mkdir(RUNTIME, RPC_DIRECTORY_MODE) !== true && access(RUNTIME, 'f') !== true) return null;

    let directory = mkdtemp(`${RUNTIME}/rpc-XXXXXX`);
    if (!directory) return null;

    let path = `${directory}/payload`;
    let file = open(path, 'wx', RPC_FILE_MODE);
    if (!file) {
        rmdir(directory);
        return null;
    }

    let written = file.write(content);
    let closed = file.close();
    if (written == null || written !== length(content) || closed !== true || chmod(path, RPC_FILE_MODE) !== true) {
        unlink(path);
        rmdir(directory);
        return null;
    }

    return { directory, path };
}

function remove_payload(payload) {
    if (!payload) return;
    if (payload.path) unlink(payload.path);
    if (payload.directory) rmdir(payload.directory);
}

function defer_ctl(request, args, label) {
    return defer_exec(request, CTL, args, label);
}

function defer_rpc_helper(request, command, label) {
    return defer_exec(request, '/usr/bin/ucode', [ RPC_HELPER, command ], label);
}

function defer_update(request, command, kind, value, label) {
    let params = [ UPDATE, command ];
    if (kind != null) push(params, `${kind}`);
    if (value != null) push(params, `${value}`);
    return defer_exec(request, '/usr/bin/ucode', params, label);
}

function defer_ctl_file(request, command, value, label) {
    value = `${value == null ? '' : value}`;
    if (length(value) > RPC_PAYLOAD_MAX_BYTES)
        return { ok: false, error: 'editor content is larger than 32 KiB' };

    let payload = create_payload(value);
    if (!payload)
        return { ok: false, error: 'unable to create secure RPC temporary file' };

    return defer_exec(request, CTL, [ command, payload.path ], label, function() {
        remove_payload(payload);
    });
}

function valid_action(name) {
    return name == 'start' || name == 'stop' || name == 'reload' || name == 'restart';
}

function valid_update_kind(kind) {
    return kind == 'nftflow' || kind == 'xray' || kind == 'geoip' || kind == 'geosite';
}

function request_args(request) {
    return request && request.args ? request.args : {};
}

const methods = {
    status: {
        args: {},
        call: request => defer_rpc_helper(request, 'status', 'NftFlow status')
    },
    firewall_read: {
        args: {},
        call: () => firewall_read_effective()
    },
    firewall_ready: {
        args: {},
        call: () => firewall_ready()
    },
    firewall_runtime: {
        args: {},
        call: request => defer_rpc_helper(request, 'firewall-runtime', 'Firewall runtime read')
    },
    firewall_validate: {
        args: { config: '' },
        call: request => defer_ctl_file(request, 'firewall-validate-file', request_args(request).config || '', 'Firewall validation')
    },
    firewall_save: {
        args: { config: '' },
        call: request => defer_ctl_file(request, 'firewall-save-file', request_args(request).config || '', 'Firewall save')
    },
    firewall_apply: {
        args: { config: '' },
        call: request => defer_ctl_file(request, 'firewall-apply-file', request_args(request).config || '', 'Firewall apply')
    },
    routing_read: {
        args: {},
        call: request => defer_rpc_helper(request, 'routing-read', 'Routing read')
    },
    routing_runtime: {
        args: {},
        call: request => defer_rpc_helper(request, 'routing-runtime', 'Routing runtime read')
    },
    routing_validate: {
        args: { config: '' },
        call: request => defer_ctl_file(request, 'routing-validate-file', request_args(request).config || '', 'Routing validation')
    },
    routing_save: {
        args: { config: '' },
        call: request => defer_ctl_file(request, 'routing-save-file', request_args(request).config || '', 'Routing save')
    },
    routing_apply: {
        args: { config: '' },
        call: request => defer_ctl_file(request, 'routing-apply-file', request_args(request).config || '', 'Routing apply')
    },
    config_read: {
        args: {},
        call: request => defer_rpc_helper(request, 'config-read', 'Configuration read')
    },
    config_validate: {
        args: { config: '' },
        call: request => defer_ctl_file(request, 'config-validate-file', request_args(request).config || '', 'Configuration validation')
    },
    config_apply: {
        args: { config: '' },
        call: request => defer_ctl_file(request, 'config-apply-file', request_args(request).config || '', 'Configuration apply')
    },
    config_save: {
        args: { config: '' },
        call: request => defer_ctl_file(request, 'config-save-file', request_args(request).config || '', 'Configuration save')
    },
    geo_status: {
        args: {},
        call: request => defer_update(request, 'geo-status', null, null, 'GeoData status')
    },
    update_status: {
        args: {},
        call: request => defer_update(request, 'status', null, null, 'Update status')
    },
    update_check: {
        args: { kind: 'nftflow' },
        call: request => {
            let kind = request_args(request).kind || '';
            return valid_update_kind(kind)
                ? defer_update(request, 'check', kind, null, `${kind} update check`)
                : { ok: false, error: 'invalid update kind' };
        }
    },
    update_install: {
        args: { kind: 'nftflow' },
        call: request => {
            let kind = request_args(request).kind || '';
            return valid_update_kind(kind)
                ? defer_update(request, 'start', kind, null, `${kind} update start`)
                : { ok: false, error: 'invalid update kind' };
        }
    },
    update_stop: {
        args: { kind: 'nftflow' },
        call: request => {
            let kind = request_args(request).kind || '';
            return valid_update_kind(kind)
                ? defer_update(request, 'stop', kind, null, `${kind} update stop`)
                : { ok: false, error: 'invalid update kind' };
        }
    },
    update_settings: {
        args: {},
        call: request => defer_update(request, 'auto-status', null, null, 'Update settings')
    },
    update_set_check: {
        args: { enabled: 0 },
        call: request => defer_update(request, 'auto-set-check', null, request_args(request).enabled ? 1 : 0, 'Automatic update check setting')
    },
    update_set_auto: {
        args: { kind: 'nftflow', enabled: 0 },
        call: request => {
            let args = request_args(request);
            let kind = args.kind || '';
            return valid_update_kind(kind)
                ? defer_update(request, 'auto-set', kind, args.enabled ? 1 : 0, `${kind} automatic update setting`)
                : { ok: false, error: 'invalid update kind' };
        }
    },
    action: {
        args: { name: '' },
        call: request => {
            let name = request_args(request).name || '';
            return valid_action(name)
                ? defer_ctl(request, [ 'action', name ], `NftFlow ${name}`)
                : { ok: false, error: 'unsupported service action' };
        }
    },
    service_sync: {
        args: {},
        call: request => defer_ctl(request, [ 'service-sync' ], 'NftFlow service sync')
    }
};

return { 'luci.nftflow': methods };
