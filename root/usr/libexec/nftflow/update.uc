#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0
// NftFlow software, GeoData and scheduled update controller in native OpenWrt ucode.

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const SOFTWARE_DIR = '/tmp/nftflow-update';
const RUNTIME = '/var/run/nftflow';
const LOG_DIR = '/var/log/nftflow';
const PROBE_CACHE = '/tmp/openwrt-update-probe';
const PROBE_TTL = 300;
const FETCH = '/bin/uclient-fetch';
const CTL = '/usr/libexec/nftflow/nftflowctl';
const SELF = '/usr/libexec/nftflow/update.uc';
const MANIFEST_URL = 'https://github.com/madwind/luci-app-nftflow/releases/latest/download/nftflow-update.json';
const RELEASE_BASE = 'https://github.com/madwind/luci-app-nftflow/releases/download/';
const GEOIP_URL = 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat';
const GEOSITE_URL = 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat';
const PACKAGES = { nftflow: 'luci-app-nftflow', xray: 'xray-core' };
const CRONTAB = '/etc/crontabs/root';
const CRON_TAG = 'nftflow-update-weekly';
const OLD_CRON_TAG = 'nftflow-geodata-weekly';
const SCHEDULE = '17 4 * * 0';
const SCHEDULE_MINUTE = 17;
const SCHEDULE_HOUR = 4;
const SCHEDULE_DOW = 0;
const BATCH_BACKUP = `${SOFTWARE_DIR}/batch-backup`;
let sequence = 0;

function q(value) { return `'${replace(`${value == null ? '' : value}`, /'/g, `'\\''`)}'`; }
function capture(command) {
    let proc = fs.popen(`${command} 2>&1`, 'r');
    if (!proc) return { ok: false, output: 'unable to execute command', code: 1 };
    let output = proc.read('all') || '';
    let rc = proc.close();
    let ok = rc === 0;
    return { ok, output, code: ok ? 0 : int(rc || 1) };
}
function quiet(command) { return system(`${command} >/dev/null 2>&1`) === 0; }
function mkdirp(path) { return quiet(`mkdir -p ${q(path)}`); }
function read_text(path) { return fs.readfile(path); }
function parse_json(raw) { try { return json(raw); } catch (e) { return null; } }
function pid() { let p = fs.popen('echo $PPID', 'r'); if (!p) return 0; let n = int(trim(p.read('all') || '0')); p.close(); return n; }
function atomic_write(path, value, mode) {
    let parent = fs.dirname(path) || '.';
    if (!mkdirp(parent)) return { ok: false, error: `cannot create ${parent}` };
    sequence++;
    let temporary = `${path}.tmp.${pid()}.${time()}.${sequence}`;
    let written = fs.writefile(temporary, value);
    if (written == null || written != length(value)) { fs.unlink(temporary); return { ok: false, error: `cannot write temporary file for ${path}` }; }
    if (mode != null && fs.chmod(temporary, mode) !== true) { fs.unlink(temporary); return { ok: false, error: `cannot chmod temporary file for ${path}` }; }
    if (fs.rename(temporary, path) !== true) { fs.unlink(temporary); return { ok: false, error: `cannot replace ${path}` }; }
    if (mode != null) fs.chmod(path, mode);
    return { ok: true };
}
function now() { return time(); }
function bool(value) { return value === true || value === 1 || value == '1' || value == 'true' || value == 'yes' || value == 'on'; }
function process_alive(process_pid) { process_pid = int(process_pid || 0); return process_pid > 1 && quiet(`kill -0 ${process_pid}`); }
function active_state(state) { return state && (state.status == 'starting' || state.status == 'running' || state.status == 'stopping') && process_alive(state.pid); }
function compact_error(output) {
    let lines = [];
    for (let line in split(`${output == null ? '' : output}`, /\r?\n/)) if (trim(line)) push(lines, trim(line));
    if (length(lines) > 6) lines = slice(lines, length(lines) - 6);
    return join(' | ', lines);
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
function uci_get(option, fallback) {
    let ctx = cursor();
    let value = ctx.get('nftflow', 'main', option);
    return value == null || `${value}` == '' ? fallback : `${value}`;
}
function uci_set_flag(option, enabled) {
    let ctx = cursor();
    ctx.set('nftflow', 'main', option, enabled ? '1' : '0');
    return ctx.commit('nftflow') === true;
}
function valid_kind(kind) { return kind == 'nftflow' || kind == 'xray' || kind == 'geoip' || kind == 'geosite'; }
function software_kind(kind) { return kind == 'nftflow' || kind == 'xray'; }
function geo_kind(kind) { return kind == 'geoip' || kind == 'geosite'; }
function state_path(kind) { return software_kind(kind) ? `${SOFTWARE_DIR}/${kind}.json` : `${RUNTIME}/geo-update-${kind}.json`; }
function lock_path(kind) { return software_kind(kind) ? `${SOFTWARE_DIR}/${kind}.lock` : `${RUNTIME}/geo-update-${kind}.lock`; }
function log_path(kind) { return software_kind(kind) ? `${SOFTWARE_DIR}/${kind}.log` : `${LOG_DIR}/geo-update-${kind}.log`; }
function remove_lock(kind) { quiet(`rmdir ${q(lock_path(kind))}`); }
function read_state(kind) {
    let value = parse_json(read_text(state_path(kind)) || '');
    if (type(value) != 'object') value = { kind, status: 'idle' };
    value.kind = kind;
    return value;
}
function save_state(kind, state) {
    state.kind = kind;
    if (!mkdirp(software_kind(kind) ? SOFTWARE_DIR : RUNTIME)) return { ok: false, error: 'cannot create update state directory' };
    return atomic_write(state_path(kind), sprintf('%J\n', state), 0o600);
}
function last_update(state) {
    if (!state) return null;
    let value = int(state.last_update || 0);
    return value || (state.updated === true ? int(state.finished || 0) || null : null);
}
function normalize_state(kind, state) {
    if ((state.status == 'starting' || state.status == 'running' || state.status == 'stopping') && state.pid && !process_alive(state.pid)) {
        state.ok = false; state.status = 'failed'; state.phase = 'failed'; state.finished = now(); state.pid = null; state.updated = false;
        state.error = geo_kind(kind) ? 'GeoData update worker exited unexpectedly' : 'update worker exited unexpectedly';
        save_state(kind, state); remove_lock(kind);
    }
    return state;
}
function installed_version(package_name) {
    let result = capture(`apk list -I ${q(package_name)}`);
    if (!result.ok) return null;
    let prefix = `${package_name}-`;
    for (let line in split(result.output || '', /\r?\n/)) {
        let token = match(line, /^(\S+)/);
        token = token ? token[1] : null;
        if (token && substr(token, 0, length(prefix)) == prefix) return substr(token, length(prefix));
    }
    return null;
}
function version_relation(left, right) {
    if (!left || !right) return null;
    let result = capture(`apk version -t ${q(left)} ${q(right)}`);
    if (!result.ok) return null;
    let rel = match(trim(result.output || ''), /[<=>]/);
    return rel ? rel[0] : null;
}
function update_available(installed, latest) { let rel = version_relation(latest, installed); return rel == null ? null : rel == '>'; }
function newest_version(package_name, output) {
    let prefix = `${package_name}-`, newest = null;
    for (let line in split(output || '', /\r?\n/)) {
        let found = match(line, /^(\S+)/), token = found ? found[1] : null;
        if (!token || substr(token, 0, length(prefix)) != prefix) continue;
        let candidate = substr(token, length(prefix));
        if (!newest || version_relation(candidate, newest) == '>') newest = candidate;
    }
    return newest;
}
function fetch_file(url, path, timeout) {
    if (!match(`${url == null ? '' : url}`, /^https:\/\//)) return { ok: false, error: 'download URL must use HTTPS' };
    if (!quiet(`[ -x ${q(FETCH)} ]`)) return { ok: false, error: 'uclient-fetch is unavailable' };
    fs.unlink(path);
    let result = capture(`${q(FETCH)} -T ${int(timeout || 15)} -O ${q(path)} ${q(url)}`);
    if (result.ok) return { ok: true };
    fs.unlink(path);
    let detail = compact_error(result.output || '') || `uclient-fetch exited with status ${result.code}`;
    return { ok: false, error: detail };
}
function temporary(base) { sequence++; return `${base}.tmp.${pid()}.${now()}.${sequence}`; }

function validate_manifest(manifest) {
    if (type(manifest) != 'object') return { ok: false, error: 'update manifest is not valid JSON' };
    let version = trim(`${manifest.version == null ? '' : manifest.version}`), tag = trim(`${manifest.tag == null ? '' : manifest.tag}`), asset = trim(`${manifest.asset == null ? '' : manifest.asset}`), sha256 = lc(trim(`${manifest.sha256 == null ? '' : manifest.sha256}`));
    if (!version || !match(version, /^[A-Za-z0-9._+-]+$/)) return { ok: false, error: 'update manifest has an invalid version' };
    if (!tag || !match(tag, /^[A-Za-z0-9._+-]+$/)) return { ok: false, error: 'update manifest has an invalid tag' };
    if (!asset || index(asset, '/') >= 0 || !match(asset, /^luci-app-nftflow-.+\.apk$/)) return { ok: false, error: 'update manifest has an invalid package asset' };
    if (length(sha256) != 64 || !match(sha256, /^[0-9a-f]+$/)) return { ok: false, error: 'update manifest has an invalid SHA256' };
    return { ok: true, manifest: { version, tag, asset, sha256, url: `${RELEASE_BASE}${tag}/${asset}` } };
}
function probe_nftflow() {
    if (!mkdirp(SOFTWARE_DIR)) return { ok: false, kind: 'nftflow', error: 'cannot create update directory' };
    let path = temporary(`${SOFTWARE_DIR}/manifest`), fetched = fetch_file(MANIFEST_URL, path, 15);
    if (!fetched.ok) {
        if (index(fetched.error || '', '404') >= 0) return { ok: true, kind: 'nftflow', installed_version: installed_version(PACKAGES.nftflow), update_available: false, no_release: true };
        return { ok: false, kind: 'nftflow', error: `NftFlow release check failed: ${fetched.error}` };
    }
    let parsed = validate_manifest(parse_json(read_text(path) || '')); fs.unlink(path);
    if (!parsed.ok) return { ok: false, kind: 'nftflow', error: parsed.error };
    let installed = installed_version(PACKAGES.nftflow);
    return { ok: true, kind: 'nftflow', installed_version: installed, latest_version: parsed.manifest.version, update_available: update_available(installed, parsed.manifest.version), manifest: parsed.manifest };
}
function probe_xray() {
    let installed = installed_version(PACKAGES.xray);
    if (!installed) return { ok: false, kind: 'xray', error: 'xray-core is not installed' };
    let refreshed = capture('apk update');
    if (!refreshed.ok) return { ok: false, kind: 'xray', error: `apk update failed: ${compact_error(refreshed.output)}` };
    let listed = capture(`apk list -a ${q(PACKAGES.xray)}`);
    if (!listed.ok) return { ok: false, kind: 'xray', error: `unable to list xray-core versions: ${compact_error(listed.output)}` };
    let latest = newest_version(PACKAGES.xray, listed.output);
    if (!latest) return { ok: false, kind: 'xray', error: 'xray-core is unavailable from configured APK repositories' };
    return { ok: true, kind: 'xray', installed_version: installed, latest_version: latest, update_available: update_available(installed, latest) };
}
function check_software(kind) {
    let current = normalize_state(kind, read_state(kind));
    if (active_state(current)) return { ok: false, kind, error: 'an update is already in progress' };
    let result = kind == 'nftflow' ? probe_nftflow() : probe_xray();
    let state = {
        ok: true, kind, status: 'idle', installed_version: current.installed_version, latest_version: current.latest_version,
        update_available: null, no_release: current.no_release === true, last_update: last_update(current), checked: now(), check_ok: result.ok === true
    };
    if (result.ok === true) {
        state.installed_version = result.installed_version || installed_version(PACKAGES[kind]) || state.installed_version;
        state.latest_version = result.latest_version; state.update_available = result.update_available; state.no_release = result.no_release === true; state.last_check_error = null;
        if (kind == 'nftflow' && result.manifest) {
            state.release_tag = result.manifest.tag; state.asset = result.manifest.asset; state.sha256 = result.manifest.sha256; state.download_url = result.manifest.url;
        }
    } else {
        state.installed_version = installed_version(PACKAGES[kind]) || state.installed_version;
        state.last_check_error = result.error || 'update check failed';
    }
    save_state(kind, state);
    result.checked = state.checked; result.check_ok = state.check_ok; result.last_check_error = state.last_check_error; result.last_update = state.last_update;
    return result;
}
function set_phase(kind, state, phase, message) { state.ok = true; state.status = 'running'; state.phase = phase; state.message = message; state.pid = pid(); save_state(kind, state); }
function fail_worker(kind, state, message) {
    state.ok = false; state.status = 'failed'; state.phase = 'failed'; state.finished = now(); state.error = message || 'update failed'; state.pid = null; state.updated = false;
    save_state(kind, state); remove_lock(kind); return state;
}
function append_post_error(state, message) { if (!message) return; state.post_check_error = state.post_check_error ? `${state.post_check_error} ${message}` : message; }
function verify_installed(kind, state, expected) {
    let installed = installed_version(PACKAGES[kind]); state.installed_version = installed || state.installed_version; state.post_check_error = null;
    if (!installed) { state.post_check_error = `Unable to verify the installed ${kind == 'nftflow' ? 'NftFlow' : 'xray-core'} version after update.`; return false; }
    let relation = version_relation(installed, expected);
    if (relation == '=' || relation == '>') { state.update_available = false; return true; }
    if (relation == '<') { state.update_available = true; state.post_check_error = 'The installed version is still older than the checked version.'; return false; }
    state.post_check_error = 'Unable to compare the installed version after update.'; return false;
}
function done_worker(kind, state, message) {
    state.ok = true; state.status = 'done'; state.phase = 'done'; state.finished = now(); state.updated = true; state.last_update = state.finished; state.error = null; state.message = message; state.pid = null;
    save_state(kind, state); remove_lock(kind); return state;
}
function worker_nftflow(state) {
    if (!state.download_url || !state.sha256 || !state.latest_version) return fail_worker('nftflow', state, 'cached NftFlow check data is incomplete; check updates again');
    let defer_restart = state.defer_restart === true;
    let was_running = quiet('/etc/init.d/nftflow running');
    let package_path = temporary(`${SOFTWARE_DIR}/${state.asset || 'luci-app-nftflow.apk'}`);
    set_phase('nftflow', state, 'downloading', 'Downloading checked NftFlow package');
    let fetched = fetch_file(state.download_url, package_path, 15);
    if (!fetched.ok) return fail_worker('nftflow', state, `NftFlow download failed: ${fetched.error}`);
    set_phase('nftflow', state, 'verifying', 'Verifying NftFlow package');
    let hash = capture(`sha256sum ${q(package_path)}`), found = hash.ok ? match(hash.output || '', /^([0-9A-Fa-f]+)/) : null;
    let actual = found ? lc(found[1]) : null;
    if (!actual || actual != lc(`${state.sha256}`)) { fs.unlink(package_path); return fail_worker('nftflow', state, 'NftFlow SHA256 verification failed'); }
    let simulated = capture(`apk --network=no add --allow-untrusted --simulate --upgrade ${q(package_path)}`);
    if (!simulated.ok) { fs.unlink(package_path); return fail_worker('nftflow', state, `NftFlow package cannot be installed offline after download: ${compact_error(simulated.output)}`); }
    set_phase('nftflow', state, 'installing', 'Installing NftFlow package');
    if (was_running && !defer_restart && !quiet('/etc/init.d/nftflow stop')) { fs.unlink(package_path); return fail_worker('nftflow', state, 'Unable to stop NftFlow before package installation'); }
    let prefix = defer_restart ? 'NFTFLOW_DEFER_RESTART=1 ' : '';
    let installed = capture(`${prefix}apk --network=no add --allow-untrusted --upgrade ${q(package_path)}`); fs.unlink(package_path);
    if (was_running && !defer_restart && !quiet('/etc/init.d/nftflow start')) append_post_error(state, 'NftFlow did not restart after package installation.');
    if (!installed.ok) return fail_worker('nftflow', state, `NftFlow installation failed: ${compact_error(installed.output)}`);
    let restart_error = state.post_check_error; verify_installed('nftflow', state, state.latest_version); if (restart_error) append_post_error(state, restart_error);
    return done_worker('nftflow', state, 'NftFlow updated successfully');
}
function worker_xray(state) {
    let expected = state.latest_version;
    if (!expected) return fail_worker('xray', state, 'cached Xray check data is incomplete; check updates again');
    let defer_restart = state.defer_restart === true, was_running = quiet('/etc/init.d/nftflow running');
    let download_dir = temporary(`${SOFTWARE_DIR}/xray-cache`);
    if (!mkdirp(download_dir)) return fail_worker('xray', state, 'cannot create xray-core download directory');
    let constraint = `${PACKAGES.xray}=${expected}`;
    set_phase('xray', state, 'downloading', 'Downloading checked xray-core version');
    let fetched = capture(`apk fetch --output ${q(download_dir)} ${q(constraint)}`);
    if (!fetched.ok) { quiet(`rm -rf ${q(download_dir)}`); return fail_worker('xray', state, `xray-core download failed: ${compact_error(fetched.output)}`); }
    set_phase('xray', state, 'verifying', 'Verifying xray-core package and offline dependencies');
    let cache_option = `--cache-dir ${q(download_dir)}`;
    let simulated = capture(`apk ${cache_option} --network=no add --simulate --upgrade ${q(constraint)}`);
    if (!simulated.ok) { quiet(`rm -rf ${q(download_dir)}`); return fail_worker('xray', state, `xray-core package cannot be installed offline after download: ${compact_error(simulated.output)}`); }
    set_phase('xray', state, 'installing', 'Installing checked xray-core version');
    if (was_running && !defer_restart && !quiet('/etc/init.d/nftflow stop')) { quiet(`rm -rf ${q(download_dir)}`); return fail_worker('xray', state, 'Unable to stop NftFlow before xray-core installation'); }
    let installed = capture(`apk ${cache_option} --network=no add --upgrade ${q(constraint)}`); quiet(`rm -rf ${q(download_dir)}`);
    if (was_running && !defer_restart && !quiet('/etc/init.d/nftflow start')) append_post_error(state, 'NftFlow did not restart after xray-core installation.');
    if (!installed.ok) return fail_worker('xray', state, `xray-core installation failed: ${compact_error(installed.output)}`);
    let restart_error = state.post_check_error; verify_installed('xray', state, expected); if (restart_error) append_post_error(state, restart_error);
    return done_worker('xray', state, 'Xray Core updated successfully');
}

function geo_config(kind) {
    let dir = uci_get('asset_dir', '/usr/share/xray');
    if (kind == 'geoip') return { path: uci_get('geoip_file', `${dir}/geoip.dat`), url: uci_get('geoip_url', GEOIP_URL) };
    if (kind == 'geosite') return { path: uci_get('geosite_file', `${dir}/geosite.dat`), url: uci_get('geosite_url', GEOSITE_URL) };
    return null;
}
function version_path(kind) { let cfg = geo_config(kind); return cfg ? `${cfg.path}.version` : null; }
function read_geo_version(kind) { let path = version_path(kind); let value = path ? trim(read_text(path) || '') : ''; return value || null; }
function write_geo_version(kind, version) {
    let path = version_path(kind); if (!path) return { ok: false, error: 'unsupported GeoData kind' };
    version = trim(`${version == null ? '' : version}`);
    if (!version) { fs.unlink(path); return { ok: true }; }
    return atomic_write(path, `${version}\n`, 0o644);
}
function geo_ready(kind) { let cfg = geo_config(kind), st = cfg ? fs.stat(cfg.path) : null; return type(st) == 'object' && int(st.size || 0) >= 1024; }
function geo_load_state(kind) {
    let state = normalize_state(kind, read_state(kind));
    if (geo_ready(kind)) {
        let version = read_geo_version(kind); if (version) { state.local_version = version; state.source_version = version; }
    } else { state.local_version = null; state.source_version = null; }
    return state;
}
function cache_key(url) {
    let result = capture(`printf '%s' ${q(url)} | sha256sum`), found = result.ok ? match(result.output || '', /^([0-9A-Fa-f]+)/) : null;
    return found ? lc(found[1]) : null;
}
function cache_paths(url) { let key = cache_key(url); return key ? { path: `${PROBE_CACHE}/${key}.json`, lock: `${PROBE_CACHE}/${key}.lock` } : null; }
function valid_cached(url) {
    let paths = cache_paths(url); if (!paths) return null;
    let st = fs.stat(paths.path);
    if (type(st) != 'object' || now() - int(st.mtime || 0) > PROBE_TTL) return null;
    let value = parse_json(read_text(paths.path) || '');
    if (type(value) != 'object' || value.url != url || !value.remote_version || !value.download_url || !value.checksum_url) return null;
    value.cache_hit = true; return value;
}
function acquire_lock(path) {
    for (let i = 0; i < 50; i++) { if (quiet(`mkdir ${q(path)}`)) return true; system('sleep 0.1'); }
    return false;
}
function probe_geo_remote(url) {
    let cached = valid_cached(url); if (cached) return cached;
    if (!mkdirp(PROBE_CACHE)) return { ok: false, url, error: 'cannot create shared update probe cache' };
    let paths = cache_paths(url); if (!paths) return { ok: false, url, error: 'cannot derive shared update probe cache key' };
    if (!acquire_lock(paths.lock)) return { ok: false, url, error: 'timed out waiting for shared update probe' };
    cached = valid_cached(url); if (cached) { quiet(`rmdir ${q(paths.lock)}`); return cached; }
    let result = capture(`${q(FETCH)} -s -T 5 ${q(url)}`);
    if (!result.ok) { quiet(`rmdir ${q(paths.lock)}`); return { ok: false, url, error: trim(result.output || 'GeoData release probe failed') }; }
    let final_match = match(result.output || '', /(https:\/\/[^\s]+\/releases\/download\/[^\s]+)/);
    let final_url = final_match ? replace(final_match[1], /[\r\n].*$/, '') : null;
    let remote_match = match(final_url || result.output || '', /\/releases\/download\/([^\/\s]+)\//);
    let remote = remote_match ? remote_match[1] : null;
    if (!final_url && remote) final_url = replace(url, '/releases/latest/download/', `/releases/download/${remote}/`);
    if (!remote || !final_url) { quiet(`rmdir ${q(paths.lock)}`); return { ok: false, url, error: 'unable to determine GeoData release version or pinned download URL' }; }
    let value = { ok: true, url, remote_version: remote, download_url: final_url, checksum_url: `${final_url}.sha256sum`, checked: now(), cache_hit: false };
    atomic_write(paths.path, sprintf('%J\n', value), 0o644); quiet(`rmdir ${q(paths.lock)}`); return value;
}
function probe_geo(kind) {
    let cfg = geo_config(kind); if (!cfg) return { ok: false, kind, error: 'unsupported GeoData kind' };
    if (!match(cfg.url, /^https:\/\//)) return { ok: false, kind, url: cfg.url, error: 'GeoData source URL must use HTTPS' };
    if (!quiet(`[ -x ${q(FETCH)} ]`)) return { ok: false, kind, url: cfg.url, error: 'uclient-fetch is unavailable' };
    let remote = probe_geo_remote(cfg.url);
    if (remote.ok !== true) return { ok: false, kind, url: cfg.url, error: remote.error || 'GeoData release probe failed' };
    let ready = geo_ready(kind), local_version = ready ? read_geo_version(kind) : null;
    return {
        ok: true, kind, url: cfg.url, local_version, remote_version: remote.remote_version,
        download_url: remote.download_url, checksum_url: remote.checksum_url,
        update_available: !local_version || remote.remote_version != local_version, cache_hit: remote.cache_hit === true
    };
}
function check_geo(kind) {
    if (!mkdirp(RUNTIME)) return { ok: false, kind, error: 'cannot create GeoData runtime directory' };
    let state = geo_load_state(kind); if (active_state(state)) return { ok: false, kind, error: 'a GeoData update is already in progress' };
    let result = probe_geo(kind);
    state.status = 'idle'; state.phase = null; state.progress = null; state.error = null; state.updated = false; state.checked = now(); state.check_ok = result.ok === true; state.last_update = last_update(state);
    if (result.ok === true) {
        state.local_version = result.local_version; state.source_version = result.local_version; state.latest_version = result.remote_version;
        state.download_url = result.download_url; state.checksum_url = result.checksum_url; state.source_url = result.url;
        state.update_available = result.update_available === true; state.cache_hit = result.cache_hit === true; state.last_check_error = null;
    } else state.last_check_error = result.error || 'GeoData check failed';
    save_state(kind, state);
    result.checked = state.checked; result.check_ok = state.check_ok; result.last_check_error = state.last_check_error; result.last_update = state.last_update;
    return result;
}
function nftflow_running() {
    let result = capture(`${q(CTL)} status`), parsed = parse_result(result.output || '');
    return result.ok && parsed && parsed.ok === true && parsed.running === true;
}
function wait_nftflow_running() {
    let stable = 0;
    for (let i = 0; i < 6; i++) {
        if (nftflow_running()) { stable++; if (stable >= 3) return true; } else stable = 0;
        system('sleep 1');
    }
    return false;
}
function restore_geo(kind, cfg, backup, had_previous, old_version, state) {
    fs.unlink(cfg.path);
    if (had_previous) {
        if (fs.rename(backup, cfg.path) !== true) return { ok: false, error: 'cannot restore previous GeoData file' };
        fs.chmod(cfg.path, 0o644);
    } else fs.unlink(backup);
    let restored = write_geo_version(kind, old_version || '');
    if (!restored.ok) return restored;
    state.local_version = old_version; state.source_version = old_version; return { ok: true };
}
function worker_geo(state) {
    let kind = state.kind, cfg = geo_config(kind);
    if (!cfg) return fail_worker(kind, state, 'unsupported GeoData kind');
    let defer_restart = state.defer_restart === true, was_running = !defer_restart && nftflow_running();
    state.pid = pid(); state.status = 'running'; state.phase = 'starting'; save_state(kind, state);
    if (state.check_ok !== true || state.update_available !== true || !state.latest_version || !state.download_url || !state.checksum_url)
        return fail_worker(kind, state, 'no complete checked GeoData update is available; check updates first');
    if (!mkdirp(fs.dirname(cfg.path) || '.')) return fail_worker(kind, state, `cannot create ${fs.dirname(cfg.path) || '.'}`);
    let expected_version = state.latest_version, download = temporary(`${cfg.path}.nftflow-download`), checksum = temporary(`${cfg.path}.nftflow-sha256`);
    set_phase(kind, state, 'downloading', 'Downloading checked GeoData release and SHA256');
    let fetched = fetch_file(state.download_url, download, 30);
    if (!fetched.ok) { fs.unlink(download); return fail_worker(kind, state, `GeoData download failed: ${fetched.error}`); }
    fetched = fetch_file(state.checksum_url, checksum, 15);
    if (!fetched.ok) { fs.unlink(download); fs.unlink(checksum); return fail_worker(kind, state, `GeoData SHA256 download failed: ${fetched.error}`); }
    set_phase(kind, state, 'verifying', 'Verifying GeoData SHA256');
    let stat = fs.stat(download);
    if (type(stat) != 'object' || int(stat.size || 0) < 1024) { fs.unlink(download); fs.unlink(checksum); return fail_worker(kind, state, 'downloaded GeoData file is empty or implausibly small'); }
    let expected_match = match(trim(read_text(checksum) || ''), /^([0-9A-Fa-f]+)/), expected = expected_match ? lc(expected_match[1]) : null;
    let hash = capture(`sha256sum ${q(download)}`), actual_match = hash.ok ? match(hash.output || '', /^([0-9A-Fa-f]+)/) : null, actual = actual_match ? lc(actual_match[1]) : null;
    fs.unlink(checksum);
    if (!expected || length(expected) != 64 || !match(expected, /^[0-9a-f]+$/) || !actual || actual != expected) { fs.unlink(download); return fail_worker(kind, state, 'GeoData SHA256 verification failed'); }
    let backup = temporary(`${cfg.path}.nftflow-backup`), previous = fs.stat(cfg.path), had_previous = type(previous) == 'object', old_version = read_geo_version(kind);
    if (had_previous && fs.rename(cfg.path, backup) !== true) { fs.unlink(download); return fail_worker(kind, state, 'cannot preserve previous GeoData file'); }
    if (fs.rename(download, cfg.path) !== true) { if (had_previous) fs.rename(backup, cfg.path); fs.unlink(download); return fail_worker(kind, state, `cannot atomically replace ${cfg.path}`); }
    fs.chmod(cfg.path, 0o644);
    let persisted = write_geo_version(kind, expected_version);
    if (!persisted.ok || read_geo_version(kind) != expected_version) {
        let restored = restore_geo(kind, cfg, backup, had_previous, old_version, state);
        return fail_worker(kind, state, restored.ok ? (persisted.error || 'installed GeoData version metadata failed local verification') : `GeoData metadata update failed and rollback failed: ${restored.error}`);
    }
    if (was_running) {
        set_phase(kind, state, 'restarting', 'Restarting NftFlow once to load updated GeoData');
        let restarted = quiet('/etc/init.d/nftflow restart');
        if (!restarted || !wait_nftflow_running()) {
            quiet('/etc/init.d/nftflow stop');
            let restored = restore_geo(kind, cfg, backup, had_previous, old_version, state);
            if (restored.ok) {
                let recovered = quiet('/etc/init.d/nftflow start') && wait_nftflow_running();
                if (!recovered) quiet('/etc/init.d/nftflow stop');
                return fail_worker(kind, state, recovered ? 'NftFlow rejected updated GeoData; previous GeoData was restored' : 'NftFlow rejected updated GeoData; previous GeoData was restored but service recovery also failed');
            }
            return fail_worker(kind, state, `NftFlow failed after GeoData update and rollback failed: ${restored.error}`);
        }
    }
    fs.unlink(backup);
    state.local_version = expected_version; state.source_version = expected_version; state.latest_version = expected_version; state.update_available = false; state.post_check_error = null;
    return done_worker(kind, state, `${kind} updated successfully`);
}
function geo_asset_status(kind) {
    let cfg = geo_config(kind), st = fs.stat(cfg.path), exists = type(st) == 'object', size = exists ? int(st.size || 0) : 0;
    let state = geo_load_state(kind), local_version = exists && size >= 1024 ? (read_geo_version(kind) || state.local_version || state.source_version) : null;
    return {
        kind, path: cfg.path, url: cfg.url, exists, size, mtime: exists ? int(st.mtime || 0) : null, ready: exists && size >= 1024,
        local_version, checked: int(state.checked || 0) || null, check_ok: state.check_ok, latest_version: state.latest_version,
        update_available: state.check_ok === true ? state.update_available : null, last_check_error: state.last_check_error,
        last_update: last_update(state), post_check_error: state.post_check_error, update: state
    };
}
function geo_status() {
    let assets = { geoip: geo_asset_status('geoip'), geosite: geo_asset_status('geosite') }, active = [];
    for (let kind in [ 'geoip', 'geosite' ]) {
        let state = assets[kind].update;
        if (state.status == 'starting' || state.status == 'running' || state.status == 'stopping') push(active, state);
    }
    let update = length(active) == 1 ? active[0] : (length(active) > 1 ? { ok: true, status: 'running', kind: 'all' } : { ok: true, status: 'idle' });
    return { ok: true, ready: assets.geoip.ready && assets.geosite.ready, assets, update };
}

function start(kind, defer_restart) {
    if (!valid_kind(kind)) return { ok: false, kind, error: 'unsupported update kind' };
    if (!mkdirp(software_kind(kind) ? SOFTWARE_DIR : RUNTIME) || (geo_kind(kind) && !mkdirp(LOG_DIR))) return { ok: false, kind, error: 'cannot create update directory' };
    let state = geo_kind(kind) ? geo_load_state(kind) : normalize_state(kind, read_state(kind));
    if (active_state(state)) { state.ok = true; return state; }
    if (state.check_ok !== true || state.update_available !== true) return { ok: false, kind, error: 'no checked update is available; run Check updates first' };
    if (kind == 'nftflow' && (!state.download_url || !state.sha256 || !state.latest_version)) return { ok: false, kind, error: 'cached NftFlow check data is incomplete; check updates again' };
    if (geo_kind(kind) && (!state.latest_version || !state.download_url || !state.checksum_url)) return { ok: false, kind, error: 'no complete checked GeoData update is available; run Check updates first' };
    remove_lock(kind);
    if (!quiet(`mkdir ${q(lock_path(kind))}`)) return { ok: false, kind, status: 'busy', error: 'another update is starting' };
    state.ok = true; state.status = 'starting'; state.phase = 'starting'; state.started = now(); state.finished = null; state.pid = null; state.updated = false;
    state.post_check_error = null; state.error = null; state.message = 'Update started'; state.defer_restart = defer_restart === true;
    if (software_kind(kind)) state.installed_version = installed_version(PACKAGES[kind]) || state.installed_version;
    let saved = save_state(kind, state);
    if (!saved.ok) { remove_lock(kind); return { ok: false, kind, status: 'failed', error: saved.error || 'cannot save update state' }; }
    let command = `/usr/bin/ucode ${q(SELF)} worker ${q(kind)} </dev/null >>${q(log_path(kind))} 2>&1 & echo $!`;
    let proc = fs.popen(command, 'r'), worker_pid = proc ? int(trim(proc.read('line') || '0')) : 0; if (proc) proc.close();
    if (!worker_pid) { remove_lock(kind); state.ok = false; state.status = 'failed'; state.phase = 'failed'; state.error = 'unable to start update worker'; save_state(kind, state); return state; }
    state.pid = worker_pid; save_state(kind, state); return state;
}
function worker(kind) {
    if (!valid_kind(kind)) return { ok: false, kind, error: 'unsupported update kind' };
    let state = geo_kind(kind) ? geo_load_state(kind) : read_state(kind);
    state.pid = pid(); state.status = 'running'; state.phase = 'starting'; state.started = int(state.started || 0) || now(); save_state(kind, state);
    if (state.check_ok !== true || state.update_available !== true) return fail_worker(kind, state, 'no checked update is available; check updates first');
    if (kind == 'nftflow') return worker_nftflow(state);
    if (kind == 'xray') return worker_xray(state);
    return worker_geo(state);
}
function software_component_status(kind) {
    let state = normalize_state(kind, read_state(kind)), installed = installed_version(PACKAGES[kind]), latest = state.latest_version;
    let available = state.check_ok === true && latest ? update_available(installed, latest) : null;
    return {
        kind, installed_version: installed, latest_version: latest, update_available: available, no_release: state.no_release === true,
        checked: state.checked, check_ok: state.check_ok, last_check_error: state.last_check_error, last_update: last_update(state),
        post_check_error: state.post_check_error, operation: state
    };
}
function software_status() { return { ok: true, components: { nftflow: software_component_status('nftflow'), xray: software_component_status('xray') } }; }
function worker_matches(process_pid, kind) {
    let raw = read_text(`/proc/${process_pid}/cmdline`); if (raw == null) return false;
    let command = replace(raw, /\0/g, ' ');
    return index(command, SELF) >= 0 && index(command, 'worker') >= 0 && index(command, kind) >= 0;
}
function collect_children(process_pid, result, seen) {
    if (seen[process_pid]) return; seen[process_pid] = true;
    let raw = read_text(`/proc/${process_pid}/task/${process_pid}/children`) || '';
    for (let child_text in split(trim(raw), /\s+/)) {
        let child = int(child_text || 0); if (!child || child <= 1 || seen[child]) continue;
        collect_children(child, result, seen); push(result, child);
    }
}
function any_alive(process_pid, children) { if (process_alive(process_pid)) return true; for (let child in children) if (process_alive(child)) return true; return false; }
function terminate_tree(process_pid) {
    let children = []; collect_children(process_pid, children, {});
    for (let child in children) quiet(`kill -TERM ${child}`); quiet(`kill -TERM ${process_pid}`);
    for (let i = 0; i < 3; i++) { if (!any_alive(process_pid, children)) return true; system('sleep 1'); }
    for (let child in children) if (process_alive(child)) quiet(`kill -KILL ${child}`); if (process_alive(process_pid)) quiet(`kill -KILL ${process_pid}`);
    return !any_alive(process_pid, children);
}
function stop(kind) {
    if (!valid_kind(kind)) return { ok: false, kind, error: 'unsupported update kind' };
    let state = normalize_state(kind, read_state(kind)), active = state.status == 'starting' || state.status == 'running' || state.status == 'stopping', process_pid = int(state.pid || 0);
    if (!active || process_pid <= 1 || !process_alive(process_pid)) return { ok: false, kind, status: state.status, error: 'no active update to stop' };
    if (kind == 'xray') return { ok: false, kind, status: state.status, error: 'Xray Core package update cannot be stopped safely' };
    if (kind == 'nftflow' && state.phase == 'installing') return { ok: false, kind, status: state.status, error: 'NftFlow package installation cannot be stopped safely' };
    if (!worker_matches(process_pid, kind)) return { ok: false, kind, status: state.status, error: 'refusing to stop an unexpected process' };
    state.status = 'stopping'; state.message = 'Stopping update'; state.error = null; save_state(kind, state);
    if (!terminate_tree(process_pid)) { state.ok = false; state.status = 'failed'; state.finished = now(); state.error = 'unable to stop update worker'; save_state(kind, state); return state; }
    remove_lock(kind); state.ok = true; state.status = 'stopped'; state.phase = 'stopped'; state.finished = now(); state.pid = null; state.progress = null; state.updated = false; state.error = null; state.message = 'Update stopped';
    let saved = save_state(kind, state); return saved.ok ? state : { ok: false, kind, status: 'stopped', error: saved.error || 'cannot save stopped update state' };
}
function check(kind) { return software_kind(kind) ? check_software(kind) : (geo_kind(kind) ? check_geo(kind) : { ok: false, kind, error: 'unsupported update kind' }); }

function flag(option) { return bool(uci_get(option, '0')); }
function auto_option(kind) { return `${kind}_auto_update`; }
function days_in_month(year, month) {
    if (month == 1 || month == 3 || month == 5 || month == 7 || month == 8 || month == 10 || month == 12) return 31;
    if (month == 4 || month == 6 || month == 9 || month == 11) return 30;
    if (month == 2) return (year % 400 == 0 || (year % 4 == 0 && year % 100 != 0)) ? 29 : 28;
    return null;
}
function next_check_local() {
    let date = capture(`date '+%Y %m %d %w %H %M'`); if (!date.ok) return null;
    let fields = split(trim(date.output || ''), /\s+/); if (length(fields) != 6) return null;
    let year = int(fields[0]), month = int(fields[1]), day = int(fields[2]), dow = int(fields[3]), hour = int(fields[4]), minute = int(fields[5]);
    let days = (SCHEDULE_DOW - dow + 7) % 7;
    if (days == 0 && (hour > SCHEDULE_HOUR || (hour == SCHEDULE_HOUR && minute >= SCHEDULE_MINUTE))) days = 7;
    while (days-- > 0) {
        let dim = days_in_month(year, month); if (!dim) return null;
        day++; if (day > dim) { day = 1; month++; if (month > 12) { month = 1; year++; } }
    }
    return sprintf('%04d-%02d-%02d %02d:%02d', year, month, day, SCHEDULE_HOUR, SCHEDULE_MINUTE);
}
function reload_cron() { if (!quiet('pidof crond')) return true; return quiet('/etc/init.d/cron reload') || quiet('/etc/init.d/cron restart'); }
function clear_schedule_lines() {
    let raw = read_text(CRONTAB); if (raw == null) return true;
    let kept = [];
    for (let line in split(raw, '\n')) if (index(line, CRON_TAG) < 0 && index(line, OLD_CRON_TAG) < 0) push(kept, line);
    let content = join('\n', kept); if (content && substr(content, -1) != '\n') content += '\n';
    return atomic_write(CRONTAB, content, 0o600).ok === true;
}
function auto_sync() {
    if (!mkdirp('/etc/crontabs')) return { ok: false, error: 'cannot create crontab directory' };
    if (read_text(CRONTAB) == null && atomic_write(CRONTAB, '', 0o600).ok !== true) return { ok: false, error: 'cannot create root crontab' };
    if (!clear_schedule_lines()) return { ok: false, error: 'cannot update root crontab' };
    if (flag('update_check_enabled')) {
        let raw = read_text(CRONTAB) || '';
        if (raw && substr(raw, -1) != '\n') raw += '\n';
        raw += `${SCHEDULE} /usr/bin/ucode ${SELF} auto-run >/dev/null 2>&1 # ${CRON_TAG}\n`;
        let saved = atomic_write(CRONTAB, raw, 0o600); if (!saved.ok) return { ok: false, error: saved.error };
    }
    reload_cron(); return auto_status();
}
function auto_remove() { if (!clear_schedule_lines()) return { ok: false, error: 'cannot remove automatic update schedule' }; reload_cron(); return auto_status(); }
function auto_status() {
    let raw = read_text(CRONTAB) || '', scheduled = index(raw, `# ${CRON_TAG}`) >= 0, next_check = scheduled ? next_check_local() : null, timezone = '';
    if (next_check) { let tz = capture(`date -d ${q(`${next_check}:00`)} +%Z`); if (!tz.ok) tz = capture('date +%Z'); timezone = trim(tz.output || ''); }
    return {
        ok: true, check_enabled: flag('update_check_enabled'), nftflow: flag('nftflow_auto_update'), xray: flag('xray_auto_update'),
        geoip: flag('geoip_auto_update'), geosite: flag('geosite_auto_update'), scheduled, schedule: SCHEDULE, next_check: next_check || '', timezone
    };
}
function auto_set_check(value) { if (!uci_set_flag('update_check_enabled', bool(value))) return { ok: false, error: 'cannot save automatic check setting' }; return auto_sync(); }
function auto_set(kind, value) { if (!valid_kind(kind)) return { ok: false, error: 'invalid update kind' }; if (!uci_set_flag(auto_option(kind), bool(value))) return { ok: false, error: 'cannot save automatic update setting' }; return auto_status(); }
function checked_update_available(kind) { let state = read_state(kind); return state.check_ok === true && state.update_available === true; }
function wait_one(kind) {
    for (let i = 0; i < 600; i++) {
        let state = read_state(kind);
        if (state.status == 'done') return state.updated === true;
        if (state.status == 'failed' || state.status == 'stopped') return false;
        system('sleep 1');
    }
    quiet(`logger -t nftflow-update ${q(`${kind} automatic update timed out`)}`); return false;
}
function geo_asset_path(kind) { let cfg = geo_config(kind); return cfg ? cfg.path : null; }
function snapshot_geo(kind) {
    let asset = geo_asset_path(kind); if (!asset || !mkdirp(BATCH_BACKUP)) return false;
    quiet(`rm -f ${q(`${BATCH_BACKUP}/${kind}.dat`)} ${q(`${BATCH_BACKUP}/${kind}.version`)} ${q(`${BATCH_BACKUP}/${kind}.had-file`)} ${q(`${BATCH_BACKUP}/${kind}.had-version`)} ${q(`${BATCH_BACKUP}/${kind}.snapshot`)}`);
    if (fs.stat(asset)) { if (!quiet(`cp -p ${q(asset)} ${q(`${BATCH_BACKUP}/${kind}.dat`)}`)) return false; fs.writefile(`${BATCH_BACKUP}/${kind}.had-file`, ''); }
    if (fs.stat(`${asset}.version`)) { if (!quiet(`cp -p ${q(`${asset}.version`)} ${q(`${BATCH_BACKUP}/${kind}.version`)}`)) return false; fs.writefile(`${BATCH_BACKUP}/${kind}.had-version`, ''); }
    return fs.writefile(`${BATCH_BACKUP}/${kind}.snapshot`, '') != null;
}
function restore_snapshot_geo(kind) {
    if (!fs.stat(`${BATCH_BACKUP}/${kind}.snapshot`)) return true;
    let asset = geo_asset_path(kind); if (!asset || !mkdirp(fs.dirname(asset) || '.')) return false;
    if (fs.stat(`${BATCH_BACKUP}/${kind}.had-file`)) { if (!quiet(`cp -p ${q(`${BATCH_BACKUP}/${kind}.dat`)} ${q(asset)}`)) return false; } else fs.unlink(asset);
    if (fs.stat(`${BATCH_BACKUP}/${kind}.had-version`)) { if (!quiet(`cp -p ${q(`${BATCH_BACKUP}/${kind}.version`)} ${q(`${asset}.version`)}`)) return false; } else fs.unlink(`${asset}.version`);
    return true;
}
function restore_all_geo() { for (let kind in [ 'geoip', 'geosite' ]) if (!restore_snapshot_geo(kind)) quiet(`logger -t nftflow-update ${q(`${kind} rollback after batch restart failure failed`)}`); }
function clear_batch_backup() { quiet(`rm -rf ${q(BATCH_BACKUP)}`); }
function auto_run() {
    let failed = false, did_update = false, was_running = nftflow_running(); clear_batch_backup();
    for (let kind in [ 'nftflow', 'xray', 'geoip', 'geosite' ]) {
        let result = check(kind); if (result.ok !== true) { quiet(`logger -t nftflow-update ${q(`${kind} scheduled check failed: ${result.error || 'unknown error'}`)}`); failed = true; }
    }
    for (let kind in [ 'geoip', 'geosite', 'xray', 'nftflow' ]) {
        if (!flag(auto_option(kind)) || !checked_update_available(kind)) continue;
        if (geo_kind(kind) && !snapshot_geo(kind)) { quiet(`logger -t nftflow-update ${q(`${kind} automatic update backup failed`)}`); failed = true; continue; }
        let started = start(kind, true);
        if (started.ok !== true) { quiet(`logger -t nftflow-update ${q(`${kind} automatic update could not start: ${started.error || 'unknown error'}`)}`); if (geo_kind(kind)) restore_snapshot_geo(kind); failed = true; continue; }
        if (wait_one(kind)) did_update = true;
        else { quiet(`logger -t nftflow-update ${q(`${kind} automatic update failed`)}`); if (geo_kind(kind)) restore_snapshot_geo(kind); failed = true; }
    }
    if (did_update && was_running) {
        quiet('/etc/init.d/nftflow restart');
        if (wait_nftflow_running()) { clear_batch_backup(); return { ok: !failed, updated: true }; }
        quiet(`logger -t nftflow-update ${q('NftFlow did not remain running after the automatic update batch; stopping retries and restoring previous GeoData')}`);
        quiet('/etc/init.d/nftflow stop'); restore_all_geo();
        if (quiet('/etc/init.d/nftflow start') && wait_nftflow_running()) quiet(`logger -t nftflow-update ${q('NftFlow recovered after restoring previous GeoData')}`);
        else { quiet('/etc/init.d/nftflow stop'); quiet(`logger -t nftflow-update ${q('NftFlow recovery failed; service was left stopped to prevent a respawn loop')}`); }
        failed = true;
    } else if (!did_update && was_running && !nftflow_running()) {
        quiet('/etc/init.d/nftflow start');
        if (!wait_nftflow_running()) { quiet('/etc/init.d/nftflow stop'); quiet(`logger -t nftflow-update ${q('NftFlow recovery after a failed automatic update did not stabilize; service was left stopped')}`); failed = true; }
    }
    clear_batch_backup(); return { ok: !failed, updated: did_update };
}

function dispatch(command, args) {
    switch (command) {
    case 'status': return software_status();
    case 'geo-status': return geo_status();
    case 'check': return check(args[0]);
    case 'start': return start(args[0], false);
    case 'worker': return worker(args[0]);
    case 'stop': return stop(args[0]);
    case 'auto-status': return auto_status();
    case 'auto-set-check': return auto_set_check(args[0]);
    case 'auto-set': return auto_set(args[0], args[1]);
    case 'auto-sync': return auto_sync();
    case 'auto-remove': return auto_remove();
    case 'auto-run': return auto_run();
    default: return { ok: false, error: 'unknown update command' };
    }
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result && result.ok === false ? 1 : 0);
