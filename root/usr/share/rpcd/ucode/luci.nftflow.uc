#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0
// Small, ACL-protected bridge between LuCI and the root-owned nftflowctl.

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

function parse_result(output) {
    let lines = split(trim(output || ''), /\r?\n/);
    for (let i = length(lines) - 1; i >= 0; i--) {
        if (!trim(lines[i])) continue;
        try { return json(trim(lines[i])); } catch (e) { /* keep looking */ }
    }
    return { ok: false, error: trim(output || 'nftflowctl returned no JSON') };
}

function shellquote(value) {
    return "'" + replace(`${value == null ? '' : value}`, /'/g, "'\\''") + "'";
}

function run_command(command) {
    let fd = popen(`${command} 2>&1`, 'r');
    if (!fd) return { ok: false, error: 'unable to execute command' };
    let output = fd.read('all') || '';
    let success = fd.close();
    let result = parse_result(output);
    if (success !== true && success !== 0 && result.ok === true) {
        result.ok = false;
        result.error = `command exited with an error: ${trim(output)}`;
    }
    return result;
}

function run_ctl(args) {
    let command = `/bin/sh ${CTL}`;
    for (let arg in args) command += ` ${shellquote(arg)}`;
    return run_command(command);
}

function run_geo_update(command, kind) {
    let line = `/usr/bin/lua ${GEO_UPDATE} ${shellquote(command)}`;
    if (kind) line += ` ${shellquote(kind)}`;
    return run_command(line);
}

function run_software_update(command, kind) {
    let line = `/usr/bin/lua ${SOFTWARE_UPDATE} ${shellquote(command)}`;
    if (kind) line += ` ${shellquote(kind)}`;
    return run_command(line);
}

function run_stop_update(kind) {
    return run_command(`/usr/bin/lua ${STOP_UPDATE} ${shellquote(kind)}`);
}

function merge_geo_cache(asset, cached) {
    if (!asset || !cached) return;
    asset.checked = cached.checked;
    asset.check_ok = cached.check_ok;
    asset.latest_version = cached.latest_version;
    asset.update_available = cached.update_available;
    asset.last_check_error = cached.last_check_error;
    asset.last_update = cached.last_update;
    asset.post_check_error = cached.post_check_error;
}

function weekly_geo_status() {
    let result = run_ctl([ 'geo', 'status' ]);
    if (!result || result.ok !== true) return result;

    let scheduled = false;
    let fd = open('/etc/crontabs/root', 'r');
    if (fd) {
        let crontab = fd.read('all') || '';
        fd.close();
        scheduled = index(crontab, GEO_CRON_TAG) >= 0;
    }

    let cached = run_geo_update('status');
    if (cached && cached.ok === true && cached.assets && result.assets) {
        merge_geo_cache(result.assets.geoip, cached.assets.geoip);
        merge_geo_cache(result.assets.geosite, cached.assets.geosite);
    }

    let schedule = scheduled ? run_geo_update('next-run') : null;
    result.auto_update = {
        scheduled: scheduled,
        interval_days: 7,
        schedule: '17 4 * * 0',
        next_update: schedule && schedule.ok === true ? schedule.next_update : null
    };
    return result;
}

function create_payload(value) {
    let directory = null;
    let path = null;
    let file = null;
    let content = `${value == null ? '' : value}`;
    if (access(RUNTIME, 'f') !== true && mkdir(RUNTIME, RPC_DIRECTORY_MODE) !== true && access(RUNTIME, 'f') !== true)
        return null;
    directory = mkdtemp(`${RUNTIME}/rpc-XXXXXX`);
    if (!directory) return null;
    path = `${directory}/payload`;
    file = open(path, 'wx', RPC_FILE_MODE);
    if (!file) {
        rmdir(directory);
        return null;
    }
    let written = file.write(content);
    let closed = file.close();
    file = null;
    if (written == null || written !== length(content) || closed !== true || chmod(path, RPC_FILE_MODE) !== true) {
        unlink(path);
        rmdir(directory);
        return null;
    }
    return { directory: directory, path: path };
}

function remove_payload(payload) {
    if (!payload) return;
    if (payload.path) unlink(payload.path);
    if (payload.directory) rmdir(payload.directory);
}

function run_ctl_file(command, value) {
    value = `${value == null ? '' : value}`;
    if (length(value) > RPC_PAYLOAD_MAX_BYTES)
        return { ok: false, error: 'editor content is larger than 32 KiB' };
    let payload = create_payload(value);
    if (!payload) return { ok: false, error: 'unable to create secure RPC temporary file' };
    let result;
    try {
        result = run_ctl([ command, payload.path ]);
    } catch (e) {
        result = { ok: false, error: `${e}` };
    }
    remove_payload(payload);
    return result;
}

function valid_action(name) {
    return name == 'start' || name == 'stop' || name == 'reload' || name == 'restart';
}

function valid_kind(kind) {
    return kind == 'geoip' || kind == 'geosite';
}

function valid_update_kind(kind) {
    return kind == 'nftflow' || kind == 'xray';
}

function valid_connectivity_target(target) {
    return target == 'baidu' || target == 'google';
}

const methods = {
    status: { args: {}, call: () => run_ctl(['status']) },
    health: { args: {}, call: () => run_ctl(['health']) },
    firewall_read: { args: {}, call: () => run_ctl(['firewall-read']) },
    firewall_validate: { args: { config: '' }, call: request => run_ctl_file('firewall-validate-file', request && request.args ? request.args.config || '' : '') },
    firewall_save: { args: { config: '' }, call: request => run_ctl_file('firewall-save-file', request && request.args ? request.args.config || '' : '') },
    firewall_apply: { args: { config: '' }, call: request => run_ctl_file('firewall-apply-file', request && request.args ? request.args.config || '' : '') },
    route_apply: { args: {}, call: () => run_ctl(['route-apply']) },
    routing_read: { args: {}, call: () => run_ctl(['routing-read']) },
    routing_validate: { args: { config: '' }, call: request => run_ctl_file('routing-validate-file', request && request.args ? request.args.config || '' : '') },
    routing_save: { args: { config: '' }, call: request => run_ctl_file('routing-save-file', request && request.args ? request.args.config || '' : '') },
    routing_apply: { args: { config: '' }, call: request => run_ctl_file('routing-apply-file', request && request.args ? request.args.config || '' : '') },
    connectivity_test: {
        args: { target: 'baidu' },
        call: request => {
            let target = request && request.args ? request.args.target || '' : '';
            if (!valid_connectivity_target(target)) return { ok: false, error: 'invalid connectivity target' };
            return run_ctl(['connectivity-test', target]);
        }
    },
    config_read: { args: {}, call: () => run_ctl(['config-read']) },
    config_validate: { args: { config: '' }, call: request => run_ctl_file('config-validate-file', request && request.args ? request.args.config || '' : '') },
    config_apply: { args: { config: '' }, call: request => run_ctl_file('config-apply-file', request && request.args ? request.args.config || '' : '') },
    config_save: { args: { config: '' }, call: request => run_ctl_file('config-save-file', request && request.args ? request.args.config || '' : '') },
    geo_status: { args: {}, call: () => weekly_geo_status() },
    geo_check: {
        args: { kind: 'geosite' },
        call: request => {
            let kind = request && request.args ? request.args.kind || '' : '';
            if (!valid_kind(kind)) return { ok: false, error: 'invalid geodata kind' };
            return run_geo_update('check', kind);
        }
    },
    geo_update: {
        args: { kind: 'geosite' },
        call: request => {
            let kind = request && request.args ? request.args.kind || '' : '';
            if (!valid_kind(kind)) return { ok: false, error: 'invalid geodata kind' };
            return run_geo_update('start', kind);
        }
    },
    geo_stop: {
        args: { kind: 'geosite' },
        call: request => {
            let kind = request && request.args ? request.args.kind || '' : '';
            if (!valid_kind(kind)) return { ok: false, error: 'invalid geodata kind' };
            return run_stop_update(kind);
        }
    },
    update_status: { args: {}, call: () => run_software_update('status') },
    update_check: {
        args: { kind: 'nftflow' },
        call: request => {
            let kind = request && request.args ? request.args.kind || '' : '';
            if (!valid_update_kind(kind)) return { ok: false, error: 'invalid update kind' };
            return run_software_update('check', kind);
        }
    },
    update_install: {
        args: { kind: 'nftflow' },
        call: request => {
            let kind = request && request.args ? request.args.kind || '' : '';
            if (!valid_update_kind(kind)) return { ok: false, error: 'invalid update kind' };
            return run_software_update('start', kind);
        }
    },
    update_stop: {
        args: { kind: 'nftflow' },
        call: request => {
            let kind = request && request.args ? request.args.kind || '' : '';
            if (!valid_update_kind(kind)) return { ok: false, error: 'invalid update kind' };
            return run_stop_update(kind);
        }
    },
    action: {
        args: { name: '' },
        call: request => {
            let name = request && request.args ? request.args.name || '' : '';
            if (!valid_action(name)) return { ok: false, error: 'unsupported service action' };
            return run_ctl(['action', name]);
        }
    },
    service_sync: { args: {}, call: () => run_ctl(['service-sync']) }
};

return { 'luci.nftflow': methods };
