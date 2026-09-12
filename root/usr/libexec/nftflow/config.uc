#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0
// Managed YAML configuration storage for NftFlow runtimes.

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const RUNTIME = '/var/run/nftflow';
const DEFAULT_CONFIG = '/etc/nftflow/config.yaml';
let sequence = 0;
let uci = cursor();

function q(value) { return `'${replace(`${value ?? ''}`, /'/g, `'\\''`)}'`; }
function capture(command) {
    let proc = fs.popen(`${command} 2>&1`, 'r');
    if (!proc) return { ok: false, output: 'unable to execute command', code: 1 };
    let output = proc.read('all') || '';
    let rc = proc.close();
    let ok = rc === true || rc === 0;
    return { ok, output, code: ok ? 0 : int(rc || 1) };
}
function quiet(command) { return system(`${command} >/dev/null 2>&1`) === 0; }
function mkdirp(path) { return quiet(`mkdir -p ${q(path)}`); }
function read_text(path) { return fs.readfile(path); }
function pid() {
    let proc = fs.popen('echo $PPID', 'r');
    if (!proc) return 0;
    let value = int(trim(proc.read('all') || '0'));
    proc.close();
    return value;
}
function atomic_write(path, value, mode) {
    let parent = fs.dirname(path) || '.';
    if (!mkdirp(parent)) return { ok: false, error: `cannot create ${parent}` };
    sequence++;
    let temporary = `${path}.tmp.${pid()}.${time()}.${sequence}`;
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
function config_path() {
    let path = null;
    try { path = uci.get('nftflow', 'main', 'config_file'); } catch (e) {}
    path = `${path || DEFAULT_CONFIG}`;
    if (!match(path, /^\/etc\/nftflow\/[A-Za-z0-9._\/-]+$/) || index(path, '/..') >= 0)
        return { ok: false, error: 'config_file must be an absolute path below /etc/nftflow' };
    return { ok: true, path };
}
function normalize(raw) {
    raw = `${raw ?? ''}`;
    raw = replace(raw, /\r\n/g, '\n');
    return replace(raw, /\r/g, '\n');
}
function read_current() {
    let resolved = config_path();
    if (!resolved.ok) return resolved;
    let raw = read_text(resolved.path);
    return { ok: true, path: resolved.path, exists: raw != null, config: raw == null ? '' : raw };
}
function apply(raw) {
    let resolved = config_path();
    if (!resolved.ok) return resolved;
    let config = normalize(raw);
    if (index(config, '\0') >= 0) return { ok: false, error: 'configuration contains a NUL byte' };

    let saved = atomic_write(resolved.path, config, 0o600);
    if (!saved.ok) return { ok: false, error: saved.error };

    if (!quiet('/etc/init.d/nftflow running'))
        return { ok: true, saved: true, applied: false, path: resolved.path, config };

    let restarted = capture('/etc/init.d/nftflow restart');
    if (!restarted.ok)
        return { ok: false, saved: true, path: resolved.path, config, error: 'configuration was saved but NftFlow restart failed', detail: trim(restarted.output || '') };

    return { ok: true, saved: true, applied: true, path: resolved.path, config, detail: trim(restarted.output || '') };
}
function read_rpc_input(path) {
    path = `${path ?? ''}`;
    if (!match(path, /^\/var\/run\/nftflow\/rpc-[A-Za-z0-9]+\/payload$/)) return { ok: false, error: 'invalid internal RPC input path' };
    let raw = read_text(path);
    return raw == null ? { ok: false, error: 'cannot read internal RPC input file' } : { ok: true, raw };
}
function dispatch(command, args) {
    if (command == 'config-read') return read_current();
    if (command == 'config-apply-file') {
        let input = read_rpc_input(args[0]);
        if (!input.ok) return { ok: false, error: input.error };
        return apply(input.raw);
    }
    return { ok: false, error: `unsupported config command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
