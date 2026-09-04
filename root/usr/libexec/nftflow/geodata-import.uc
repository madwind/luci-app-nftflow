#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0
// Validate and install locally uploaded GeoIP/GeoSite data without starting Xray.

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';

const RUNTIME = '/var/run/nftflow';
const SOFTWARE_DIR = '/tmp/nftflow-update';
const GLOBAL_LOCK = `${SOFTWARE_DIR}/update.lock`;
const GLOBAL_OWNER = `${GLOBAL_LOCK}/owner.json`;
const SERVICE_STATE = `${RUNTIME}/state.json`;
const LOCK_STALE_SECONDS = 30;
const UPLOADS = {
    geoip: '/tmp/nftflow-geoip-upload.dat',
    geosite: '/tmp/nftflow-geosite-upload.dat'
};
let sequence = 0;

function q(value) { return `'${replace(`${value == null ? '' : value}`, /'/g, `'\\''`)}'`; }
function capture(command) {
    let proc = fs.popen(`${command} 2>&1`, 'r');
    if (!proc) return { ok: false, output: 'unable to execute command' };
    let output = proc.read('all') || '';
    let rc = proc.close();
    return { ok: rc === 0, output: trim(output || '') };
}
function quiet(command) { return system(`${command} >/dev/null 2>&1`) === 0; }
function mkdirp(path) { return quiet(`mkdir -p ${q(path)}`); }
function read_text(path) { return fs.readfile(path); }
function pid() { let p = fs.popen('echo $PPID', 'r'); if (!p) return 0; let n = int(trim(p.read('all') || '0')); p.close(); return n; }
function temporary(base) { sequence++; return `${base}.${pid()}.${time()}.${sequence}`; }
function parse_json(raw) { try { return json(raw); } catch (e) { return null; } }
function bool(value) { return value === true || value === 1 || value == '1' || value == 'true' || value == 'yes' || value == 'on'; }
function process_alive(process_pid) { process_pid = int(process_pid || 0); return process_pid > 1 && quiet(`kill -0 ${process_pid}`); }
function atomic_write(path, value, mode) {
    let parent = fs.dirname(path) || '.';
    if (!mkdirp(parent)) return { ok: false, error: `cannot create ${parent}` };
    let temporary_path = temporary(`${path}.tmp`);
    let written = fs.writefile(temporary_path, value);
    if (written == null || written != length(value)) { fs.unlink(temporary_path); return { ok: false, error: `cannot write ${path}` }; }
    if (mode != null) fs.chmod(temporary_path, mode);
    if (fs.rename(temporary_path, path) !== true) { fs.unlink(temporary_path); return { ok: false, error: `cannot replace ${path}` }; }
    if (mode != null) fs.chmod(path, mode);
    return { ok: true };
}
function uci_get(option, fallback) {
    let ctx = cursor();
    let value = ctx.get('nftflow', 'main', option);
    return value == null || `${value}` == '' ? fallback : `${value}`;
}
function geo_config(kind) {
    let dir = uci_get('asset_dir', '/usr/share/xray');
    if (kind == 'geoip') return { path: uci_get('geoip_file', `${dir}/geoip.dat`), upload: UPLOADS.geoip };
    if (kind == 'geosite') return { path: uci_get('geosite_file', `${dir}/geosite.dat`), upload: UPLOADS.geosite };
    return null;
}
function update_state_path(kind) {
    if (kind == 'nftflow' || kind == 'xray') return `${SOFTWARE_DIR}/${kind}.json`;
    return `${RUNTIME}/geo-update-${kind}.json`;
}
function update_claimed(kind) {
    if (kind != 'nftflow' && kind != 'xray' && kind != 'geoip' && kind != 'geosite') return false;
    let state = parse_json(read_text(update_state_path(kind)) || '');
    if (type(state) != 'object') return false;
    if (state.status != 'starting' && state.status != 'running' && state.status != 'stopping') return false;
    if (process_alive(state.pid)) return true;
    let started = int(state.started || 0);
    return state.status == 'starting' && started > 0 && time() - started < LOCK_STALE_SECONDS;
}
function global_lock_info() {
    let value = parse_json(read_text(GLOBAL_OWNER) || '');
    return type(value) == 'object' ? value : {};
}
function global_lock_active() {
    let stat = fs.stat(GLOBAL_LOCK);
    if (type(stat) != 'object') return false;
    let info = global_lock_info(), owner = `${info.owner || ''}`, owner_pid = int(info.pid || 0), started = int(info.started || 0);
    if (update_claimed(owner) || process_alive(owner_pid)) return true;
    if (started > 0 && time() - started < LOCK_STALE_SECONDS) return true;
    return time() - int(stat.mtime || 0) < LOCK_STALE_SECONDS;
}
function clear_global_lock() {
    fs.unlink(GLOBAL_OWNER);
    quiet(`rmdir ${q(GLOBAL_LOCK)}`);
}
function acquire_global_lock(owner) {
    if (!mkdirp(SOFTWARE_DIR)) return false;
    if (!quiet(`mkdir ${q(GLOBAL_LOCK)}`)) {
        if (global_lock_active()) return false;
        clear_global_lock();
        if (!quiet(`mkdir ${q(GLOBAL_LOCK)}`)) return false;
    }
    let written = fs.writefile(GLOBAL_OWNER, sprintf('%J\n', { owner, pid: pid(), started: time() }));
    if (written == null) { clear_global_lock(); return false; }
    fs.chmod(GLOBAL_OWNER, 0o600);
    return true;
}
function release_global_lock(owner) {
    let current = `${global_lock_info().owner || ''}`;
    if (current && current != owner) return;
    clear_global_lock();
}
function read_varint_file(file) {
    let value = 0, multiplier = 1;
    for (let i = 0; i < 10; i++) {
        let raw = file.read(1);
        if (raw == null || length(raw) != 1) return { ok: false, error: 'unexpected end of file' };
        let byte = ord(raw, 0);
        value += (byte % 128) * multiplier;
        if (byte < 128) return { ok: true, value };
        multiplier *= 128;
    }
    return { ok: false, error: 'invalid protobuf varint' };
}
function read_varint(data, position) {
    let value = 0, multiplier = 1;
    for (let i = 0; i < 10; i++) {
        let byte = ord(data, position);
        if (byte == null) return { ok: false, error: 'truncated protobuf message' };
        position++;
        value += (byte % 128) * multiplier;
        if (byte < 128) return { ok: true, value, position };
        multiplier *= 128;
    }
    return { ok: false, error: 'invalid protobuf varint' };
}
function entry_kind(prefix) {
    let position = 0;
    while (position < length(prefix)) {
        let key = read_varint(prefix, position);
        if (!key.ok) return null;
        position = key.position;
        if (key.value == 10 || key.value == 18) {
            let size = read_varint(prefix, position);
            if (!size.ok) return null;
            position = size.position;
            if (position + size.value > length(prefix)) return null;
            if (key.value == 18 && size.value > 0) {
                let child = read_varint(prefix, position);
                if (!child.ok) return null;
                if (child.value == 10) return 'geoip';
                if (child.value == 8 || child.value == 18) return 'geosite';
            }
            position += size.value;
            continue;
        }
        if ((key.value % 8) == 0) {
            let value = read_varint(prefix, position);
            if (!value.ok) return null;
            position = value.position;
        } else if ((key.value % 8) == 1) position += 8;
        else if ((key.value % 8) == 5) position += 4;
        else return null;
    }
    return null;
}
function validate_geodata(kind, path) {
    let stat = fs.stat(path);
    if (type(stat) != 'object' || int(stat.size || 0) < 16) return { ok: false, error: 'uploaded file is empty or too small' };
    if (int(stat.size || 0) > 128 * 1024 * 1024) return { ok: false, error: 'uploaded file is larger than 128 MiB' };

    let file = fs.open(path, 'r');
    if (!file) return { ok: false, error: 'cannot open uploaded file' };
    let entries = 0, detected = null;

    while (true) {
        let field = file.read(1);
        if (field == null || length(field) == 0) break;
        if (ord(field, 0) != 10) { file.close(); return { ok: false, error: 'uploaded file is not a supported Xray GeoData file' }; }
        let size = read_varint_file(file);
        if (!size.ok || size.value < 1 || size.value > 64 * 1024 * 1024) { file.close(); return { ok: false, error: 'uploaded GeoData file has an invalid entry length' }; }
        let prefix_length = min(size.value, 512);
        let prefix = file.read(prefix_length);
        if (prefix == null || length(prefix) != prefix_length) { file.close(); return { ok: false, error: 'uploaded GeoData file is truncated' }; }
        if (!detected) detected = entry_kind(prefix);
        let rest = size.value - prefix_length;
        if (rest > 0 && file.seek(rest, 1) !== true) { file.close(); return { ok: false, error: 'cannot seek through uploaded GeoData file' }; }
        entries++;
    }
    file.close();

    if (!entries) return { ok: false, error: 'uploaded GeoData file contains no entries' };
    if (!detected) return { ok: false, error: 'unable to identify uploaded GeoData type' };
    if (detected != kind) return { ok: false, error: `uploaded file is ${detected == 'geoip' ? 'GeoIP' : 'GeoSite'} data, not ${kind == 'geoip' ? 'GeoIP' : 'GeoSite'}` };
    return { ok: true, entries, size: int(stat.size || 0) };
}
function nftflow_running() {
    try {
        let ubus = connect();
        if (!ubus) return false;
        let result = ubus.call('service', 'list', { name: 'nftflow' }), service = result && result.nftflow;
        if (type(service) != 'object' || type(service.instances) != 'object') return false;
        for (let name, instance in service.instances)
            if (type(instance) == 'object' && bool(instance.running)) return true;
    } catch (e) {}
    return false;
}
function nftflow_state() {
    let state = parse_json(read_text(SERVICE_STATE) || '');
    return type(state) == 'object' ? `${state.state || ''}` : '';
}
function wait_nftflow_ready() {
    let stable = 0;
    for (let i = 0; i < 45; i++) {
        if (nftflow_running() && nftflow_state() == 'ready') { stable++; if (stable >= 2) return true; }
        else stable = 0;
        system('sleep 1');
    }
    return false;
}
function restore_version(path, previous) {
    if (previous == null) { fs.unlink(path); return true; }
    return atomic_write(path, previous, 0o644).ok === true;
}
function save_local_state(kind, size) {
    let state_path = `${RUNTIME}/geo-update-${kind}.json`;
    let state = parse_json(read_text(state_path) || '') || {};
    let now = time();
    state.ok = true;
    state.kind = kind;
    state.status = 'done';
    state.phase = 'done';
    state.pid = null;
    state.finished = now;
    state.updated = true;
    state.last_update = now;
    state.local_version = 'Local';
    state.source_version = 'Local';
    state.latest_version = null;
    state.update_available = null;
    state.check_ok = null;
    state.last_check_error = null;
    state.post_check_error = null;
    state.error = null;
    state.message = `Local ${kind == 'geoip' ? 'GeoIP' : 'GeoSite'} file uploaded`;
    state.upload_size = size;
    state.batch = false;
    return atomic_write(state_path, sprintf('%J\n', state), 0o600);
}
function install(kind) {
    let cfg = geo_config(kind);
    if (!cfg) return { ok: false, error: 'kind must be geoip or geosite' };

    let checked = validate_geodata(kind, cfg.upload);
    if (!checked.ok) { fs.unlink(cfg.upload); return checked; }
    if (!mkdirp(fs.dirname(cfg.path) || '.')) { fs.unlink(cfg.upload); return { ok: false, error: `cannot create ${fs.dirname(cfg.path) || '.'}` }; }

    let stage = temporary(`${cfg.path}.nftflow-upload`);
    if (!quiet(`cp ${q(cfg.upload)} ${q(stage)}`)) { fs.unlink(cfg.upload); fs.unlink(stage); return { ok: false, error: 'cannot copy uploaded GeoData into asset directory' }; }
    fs.unlink(cfg.upload);
    fs.chmod(stage, 0o644);

    let owner = `upload-${kind}`;
    if (!acquire_global_lock(owner)) { fs.unlink(stage); return { ok: false, error: 'another update is already active or starting' }; }

    let backup = temporary(`${cfg.path}.nftflow-backup`);
    let version_path = `${cfg.path}.version`;
    let old_version = read_text(version_path);
    let previous = fs.stat(cfg.path);
    let had_previous = type(previous) == 'object';
    let was_running = nftflow_running();

    if (was_running && !quiet('/etc/init.d/nftflow stop')) {
        fs.unlink(stage); release_global_lock(owner);
        return { ok: false, error: 'Unable to stop NftFlow before installing uploaded GeoData' };
    }

    if (had_previous && fs.rename(cfg.path, backup) !== true) {
        fs.unlink(stage);
        if (was_running) { quiet('/etc/init.d/nftflow start'); wait_nftflow_ready(); }
        release_global_lock(owner);
        return { ok: false, error: 'cannot preserve previous GeoData file' };
    }
    if (fs.rename(stage, cfg.path) !== true) {
        if (had_previous) fs.rename(backup, cfg.path);
        fs.unlink(stage);
        if (was_running) { quiet('/etc/init.d/nftflow start'); wait_nftflow_ready(); }
        release_global_lock(owner);
        return { ok: false, error: `cannot replace ${cfg.path}` };
    }
    fs.chmod(cfg.path, 0o644);

    let version_saved = atomic_write(version_path, 'Local\n', 0o644);
    if (!version_saved.ok) {
        fs.unlink(cfg.path);
        if (had_previous) fs.rename(backup, cfg.path);
        restore_version(version_path, old_version);
        if (was_running) { quiet('/etc/init.d/nftflow start'); wait_nftflow_ready(); }
        release_global_lock(owner);
        return { ok: false, error: version_saved.error };
    }

    if (was_running && (!quiet('/etc/init.d/nftflow start') || !wait_nftflow_ready())) {
        quiet('/etc/init.d/nftflow stop');
        fs.unlink(cfg.path);
        if (had_previous) fs.rename(backup, cfg.path);
        restore_version(version_path, old_version);
        let recovered = quiet('/etc/init.d/nftflow start') && wait_nftflow_ready();
        if (!recovered) quiet('/etc/init.d/nftflow stop');
        release_global_lock(owner);
        return { ok: false, error: recovered
            ? 'NftFlow rejected uploaded GeoData; previous file was restored'
            : 'NftFlow rejected uploaded GeoData; previous file was restored but service recovery also failed' };
    }

    fs.unlink(backup);
    let state = save_local_state(kind, checked.size);
    release_global_lock(owner);
    if (!state.ok) return { ok: false, error: state.error || 'GeoData was installed but update state could not be saved' };
    return { ok: true, kind, path: cfg.path, size: checked.size, entries: checked.entries, version: 'Local', restarted: was_running };
}

let result;
try { result = install(ARGV[0] || ''); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result.ok === true ? 0 : 1);
