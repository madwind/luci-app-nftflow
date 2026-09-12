#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0
// NftFlow self-update controller.

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const SELF = '/usr/libexec/nftflow/update.uc';
const WORKDIR = '/tmp/nftflow-update';
const LOCK_DIR = `${WORKDIR}/lock`;
const FETCH = '/bin/uclient-fetch';
const REPO = 'madwind/luci-app-nftflow';
const API_URL = `https://api.github.com/repos/${REPO}/releases/latest`;
const INSTALLED_VERSION = '/usr/share/nftflow/installed-version';
const STATE_FILE = `${WORKDIR}/nftflow.json`;
const LOG_FILE = `${WORKDIR}/nftflow.log`;
const CRONTAB = '/etc/crontabs/root';
const CRON_TAG = 'nftflow-update-weekly';
const CRON_LINE = '17 4 * * 0 /usr/bin/ucode /usr/libexec/nftflow/update.uc auto-run >/dev/null 2>&1 # nftflow-update-weekly';
let sequence = 0;

function q(value) { return `'${replace(`${value ?? ''}`, /'/g, `'\\''`)}'`; }
function capture(command) {
    let proc = fs.popen(`${command} 2>&1`, 'r');
    if (!proc) return { ok: false, output: 'unable to execute command', code: 1 };
    let output = proc.read('all') || '';
    let rc = proc.close();
    return { ok: rc === 0, output, code: rc === 0 ? 0 : int(rc || 1) };
}
function quiet(command) { return system(`${command} >/dev/null 2>&1`) === 0; }
function mkdirp(path) { return quiet(`mkdir -p ${q(path)}`); }
function read_text(path) { return fs.readfile(path); }
function parse_json(raw) { try { return json(raw); } catch (e) { return null; } }
function now() { return time(); }
function pid() { let p = fs.popen('echo $PPID', 'r'); if (!p) return 0; let n = int(trim(p.read('all') || '0')); p.close(); return n; }
function bool(value) { return value === true || value === 1 || value == '1' || value == 'true' || value == 'yes' || value == 'on'; }
function process_alive(value) { value = int(value || 0); return value > 1 && quiet(`kill -0 ${value}`); }
function update_process_alive(value) {
    value = int(value || 0);
    if (!process_alive(value)) return false;
    let command = replace(read_text(`/proc/${value}/cmdline`) || '', /\0/g, ' ');
    return index(command, SELF) >= 0 && (index(command, 'worker') >= 0 || index(command, 'auto-run') >= 0);
}
function lock_owner() { return int(trim(read_text(`${LOCK_DIR}/pid`) || '0')); }
function active_lock_owner() { let owner = lock_owner(); return update_process_alive(owner) ? owner : 0; }
function create_update_lock() {
    if (!quiet(`mkdir ${q(LOCK_DIR)}`)) return false;
    fs.chmod(LOCK_DIR, 0o700);
    let owner = pid(), value = `${owner}\n`;
    let written = fs.writefile(`${LOCK_DIR}/pid`, value);
    if (written == null || written != length(value)) { quiet(`rm -rf ${q(LOCK_DIR)}`); return false; }
    fs.chmod(`${LOCK_DIR}/pid`, 0o600);
    return true;
}
function acquire_update_lock() {
    if (!mkdirp(WORKDIR)) return { ok: false, error: 'cannot create update directory' };
    if (create_update_lock()) return { ok: true, pid: pid() };
    let owner = active_lock_owner();
    if (owner) return { ok: false, error: 'another update is already running', pid: owner };
    if (!lock_owner()) {
        system('sleep 1');
        owner = active_lock_owner();
        if (owner) return { ok: false, error: 'another update is already running', pid: owner };
    }
    quiet(`rm -rf ${q(LOCK_DIR)}`);
    if (create_update_lock()) return { ok: true, pid: pid() };
    owner = active_lock_owner();
    return { ok: false, error: 'another update is already running', pid: owner || null };
}
function release_update_lock() {
    if (lock_owner() == pid()) quiet(`rm -rf ${q(LOCK_DIR)}`);
}
function temporary(name) { sequence++; return `${WORKDIR}/${name}.${pid()}.${now()}.${sequence}`; }
function atomic_write(path, value, mode) {
    let parent = fs.dirname(path) || '.';
    if (!mkdirp(parent)) return { ok: false, error: `cannot create ${parent}` };
    let tmp = temporary('write');
    let written = fs.writefile(tmp, value);
    if (written == null || written != length(value)) { fs.unlink(tmp); return { ok: false, error: `cannot write ${path}` }; }
    if (mode != null && fs.chmod(tmp, mode) !== true) { fs.unlink(tmp); return { ok: false, error: `cannot chmod ${path}` }; }
    if (fs.rename(tmp, path) !== true) { fs.unlink(tmp); return { ok: false, error: `cannot replace ${path}` }; }
    if (mode != null) fs.chmod(path, mode);
    return { ok: true };
}
function uci_get(option, fallback) {
    let ctx = cursor();
    let value = ctx.get('nftflow', 'main', option);
    return value == null || `${value}` == '' ? fallback : `${value}`;
}
function uci_set(option, enabled) {
    let ctx = cursor();
    ctx.set('nftflow', 'main', option, enabled ? '1' : '0');
    return ctx.commit('nftflow') === true;
}
function read_state() {
    let state = parse_json(read_text(STATE_FILE) || '');
    if (type(state) != 'object') state = { status: 'idle' };
    if ((state.status == 'starting' || state.status == 'running') && state.pid && !process_alive(state.pid)) {
        state.ok = false;
        state.status = 'failed';
        state.error = 'update worker exited unexpectedly';
        state.finished = now();
        state.pid = null;
        atomic_write(STATE_FILE, sprintf('%J\n', state), 0o600);
    }
    return state;
}
function save_state(state) {
    let previous = read_state();
    for (let key in [ 'checked', 'latest_version', 'last_update' ])
        if (!(key in state) && key in previous) state[key] = previous[key];
    if (!mkdirp(WORKDIR)) return false;
    return atomic_write(STATE_FILE, sprintf('%J\n', state), 0o600).ok === true;
}
function finish(result) {
    let ok = result.ok === true;
    let state = {
        ok, status: ok ? 'done' : 'failed', finished: now(), pid: null,
        updated: result.updated === true,
        error: ok ? null : (result.error || 'update failed'),
        message: result.message
    };
    if (result.updated === true) state.last_update = now();
    for (let key in [ 'checked', 'latest_version' ])
        if (key in result) state[key] = result[key];
    save_state(state);
    return state;
}
function installed_version() {
    let version = trim(read_text(INSTALLED_VERSION) || '');
    return version && match(version, /^[A-Za-z0-9._+~-]+$/) ? version : null;
}
function version_relation(left, right) {
    if (!left || !right) return null;
    let result = capture(`apk version -t ${q(left)} ${q(right)}`);
    if (!result.ok) return null;
    let found = match(trim(result.output || ''), /[<=>]/);
    return found ? found[0] : null;
}
function sha256(path) {
    let result = capture(`sha256sum ${q(path)}`);
    if (!result.ok) return null;
    let found = match(trim(result.output || ''), /^([0-9A-Fa-f]{64})[[:space:]]+/);
    return found ? lc(found[1]) : null;
}
function fetch_file(url, path, timeout) {
    if (!match(`${url ?? ''}`, /^https:\/\//)) return { ok: false, error: 'download URL must use HTTPS' };
    if (!quiet(`[ -x ${q(FETCH)} ]`)) return { ok: false, error: 'uclient-fetch is unavailable' };
    fs.unlink(path);
    let result = capture(`${q(FETCH)} -T ${int(timeout || 30)} -O ${q(path)} ${q(url)}`);
    if (result.ok) return { ok: true };
    fs.unlink(path);
    return { ok: false, error: trim(result.output || '') || `uclient-fetch exited with status ${result.code}` };
}
function release_asset(release, name) {
    if (type(release?.assets) != 'array') return null;
    for (let asset in release.assets)
        if (type(asset) == 'object' && `${asset.name || ''}` == name) return asset;
    return null;
}
function release_digest(asset) {
    let found = match(lc(trim(`${asset?.digest || ''}`)), /^sha256:([0-9a-f]{64})$/);
    return found ? found[1] : null;
}
function check_nftflow() {
    if (!mkdirp(WORKDIR)) return { ok: false, error: 'cannot create update directory' };
    let path = temporary('release.json');
    let fetched = fetch_file(API_URL, path, 20);
    if (!fetched.ok) return { ok: false, error: fetched.error, installed_version: installed_version() };
    let release = parse_json(read_text(path) || '');
    fs.unlink(path);
    if (type(release) != 'object') return { ok: false, error: 'latest release metadata is invalid', installed_version: installed_version() };

    let tag = trim(`${release.tag_name || ''}`);
    if (!match(tag, /^v[A-Za-z0-9._+~-]+$/)) return { ok: false, error: 'invalid release tag', installed_version: installed_version() };
    let latest = substr(tag, 1), name = `luci-app-nftflow-${latest}.apk`;
    let asset = release_asset(release, name);
    if (!asset) return { ok: false, error: 'latest release APK asset is unavailable', installed_version: installed_version() };
    let digest = release_digest(asset);
    if (!digest) return { ok: false, error: 'latest release APK digest is invalid', installed_version: installed_version() };
    let url = `${asset.browser_download_url || ''}`;
    let expected_url = `https://github.com/${REPO}/releases/download/${tag}/${name}`;
    if (url != expected_url) return { ok: false, error: 'latest release APK URL is invalid', installed_version: installed_version() };

    let installed = installed_version();
    return {
        ok: true, checked: now(), installed_version: installed,
        latest_version: latest,
        update_available: installed ? version_relation(latest, installed) == '>' : true,
        release: { tag, asset: name, sha256: digest, url }
    };
}
function check() {
    let owner = active_lock_owner();
    if (owner) return { ok: false, error: 'an update is already running', pid: owner };
    let result = check_nftflow();
    save_state({
        ok: result.ok === true,
        status: 'idle',
        checked: result.checked || now(),
        latest_version: result.latest_version || null,
        error: result.ok === true ? null : result.error
    });
    return result;
}
function update_nftflow(checked) {
    if (checked.update_available !== true)
        return { ok: true, updated: false, message: 'NftFlow is already up to date.' };

    let apk = temporary(checked.release.asset || 'nftflow.apk');
    let fetched = fetch_file(checked.release.url, apk, 60);
    if (!fetched.ok) return fetched;
    let actual = sha256(apk);
    if (!actual || actual != checked.release.sha256) {
        fs.unlink(apk);
        return { ok: false, error: 'NftFlow package SHA256 verification failed', expected: checked.release.sha256, actual };
    }
    let installed = capture(`apk add --allow-untrusted --upgrade ${q(apk)}`);
    fs.unlink(apk);
    if (!installed.ok) return { ok: false, error: trim(installed.output || '') || 'apk upgrade failed' };
    return { ok: true, updated: true, message: 'NftFlow updated.' };
}
function update() {
    let checked = check_nftflow();
    if (!checked.ok) return checked;
    let result = update_nftflow(checked);
    result.checked = checked.checked;
    result.latest_version = checked.latest_version;
    return result;
}
function run_update() {
    try {
        if (!save_state({ ok: true, status: 'running', started: now(), pid: pid() }))
            return finish({ ok: false, error: 'cannot save update state' });
        return finish(update());
    } catch (e) {
        return finish({ ok: false, error: `${e}` });
    }
}
function worker() {
    let acquired = false, state;
    try {
        let locked = acquire_update_lock();
        if (!locked.ok) state = finish({ ok: false, error: locked.error });
        else { acquired = true; state = run_update(); }
    } catch (e) {
        state = finish({ ok: false, error: `${e}` });
    }
    if (acquired) release_update_lock();
    return state;
}
function start() {
    let owner = active_lock_owner();
    if (owner) return { ok: false, error: 'another update is already running', pid: owner };
    let current = read_state();
    if ((current.status == 'starting' || current.status == 'running') && process_alive(current.pid))
        return { ok: false, error: 'an update is already running', state: current };
    if (!mkdirp(WORKDIR)) return { ok: false, error: 'cannot create update directory' };
    if (!save_state({ ok: true, status: 'starting', started: now(), pid: null }))
        return { ok: false, error: 'cannot save update state' };
    let spawned = capture(`/usr/bin/ucode ${q(SELF)} worker </dev/null >${q(LOG_FILE)} 2>&1 & echo $!`);
    let worker_pid = int(trim(spawned.output || '0'));
    if (!spawned.ok || worker_pid < 2) return finish({ ok: false, error: 'unable to start update worker' });
    current = read_state();
    if (current.status == 'starting' && int(current.pid || 0) < 2) {
        current.pid = worker_pid;
        save_state(current);
    }
    return { ok: true, status: 'starting', pid: worker_pid };
}
function status() {
    let state = read_state();
    state.update_available = null;
    state.installed_version = installed_version();
    if (state.latest_version)
        state.update_available = state.installed_version ? version_relation(state.latest_version, state.installed_version) == '>' : true;
    return { ok: true, component: state };
}
function auto_status() {
    let scheduled = false, crontab = read_text(CRONTAB) || '';
    for (let line in split(crontab, '\n')) if (index(line, `# ${CRON_TAG}`) >= 0) scheduled = true;
    return {
        ok: true,
        check_enabled: bool(uci_get('update_check_enabled', '0')),
        scheduled,
        auto_update: bool(uci_get('nftflow_auto_update', '0'))
    };
}
function sync_cron() {
    let enabled = bool(uci_get('update_check_enabled', '0'));
    let raw = read_text(CRONTAB) || '', lines = [];
    for (let line in split(raw, '\n')) {
        if (index(line, `# ${CRON_TAG}`) >= 0) continue;
        if (trim(line)) push(lines, line);
    }
    if (enabled) push(lines, CRON_LINE);
    let content = length(lines) ? join('\n', lines) + '\n' : '';
    if (!mkdirp(fs.dirname(CRONTAB) || '.')) return { ok: false, error: 'cannot create crontab directory' };
    let saved = atomic_write(CRONTAB, content, 0o600);
    if (!saved.ok) return saved;
    quiet('/etc/init.d/cron reload');
    return { ok: true, scheduled: enabled };
}
function set_check(enabled) {
    if (!uci_set('update_check_enabled', enabled)) return { ok: false, error: 'cannot save update check setting' };
    return sync_cron();
}
function set_auto(enabled) {
    if (!uci_set('nftflow_auto_update', enabled)) return { ok: false, error: 'cannot save automatic update setting' };
    return auto_status();
}
function auto_run() {
    if (!bool(uci_get('nftflow_auto_update', '0'))) return { ok: true, skipped: true };
    let locked = acquire_update_lock();
    if (!locked.ok) return locked;
    let result;
    try { result = run_update(); }
    catch (e) { result = { ok: false, error: `${e}` }; }
    release_update_lock();
    return result;
}
function dispatch(command, args) {
    if (command == 'status') return status();
    if (command == 'check') return check();
    if (command == 'start') return start();
    if (command == 'worker') return worker();
    if (command == 'auto-status') return auto_status();
    if (command == 'auto-set-check') return set_check(bool(args[0]));
    if (command == 'auto-set') return set_auto(bool(args[0]));
    if (command == 'auto-sync') return sync_cron();
    if (command == 'auto-run') return auto_run();
    return { ok: false, error: `unsupported update command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
