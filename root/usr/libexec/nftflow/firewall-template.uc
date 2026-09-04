#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0
// Preserve editable nftables templates while resolving runtime-only values.

'use strict';

import * as fs from 'fs';

const ENGINE = '/usr/libexec/nftflow/firewall.uc';
const SOURCE = '/etc/nftflow/firewall.nft';
const DEFAULT_SOURCE = '/usr/share/nftflow/defaults/firewall.nft';
const RUNTIME = '/var/run/nftflow';
const CANDIDATE = `${RUNTIME}/firewall.candidate.nft`;
let sequence = 0;

function q(value) { return `'${replace(`${value ?? ''}`, /'/g, `'\\''`)}'`; }
function capture(command) {
    let proc = fs.popen(`${command} 2>&1`, 'r');
    if (!proc) return { ok: false, output: 'unable to execute command' };
    let output = proc.read('all') || '';
    let rc = proc.close();
    return { ok: rc === true || rc === 0, output };
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
function normalize(raw) {
    raw = replace(`${raw ?? ''}`, /\r\n/g, '\n');
    raw = replace(raw, /\r/g, '\n');
    if (raw && substr(raw, -1) != '\n') raw += '\n';
    return raw;
}
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
function uci_get(option, fallback) {
    let result = capture(`/sbin/uci -q get nftflow.main.${option}`);
    let value = trim(result.output || '');
    return result.ok && value ? value : fallback;
}
function parse_json(raw) { try { return json(raw); } catch (e) { return null; } }
function parse_result(output) {
    let lines = split(trim(output || ''), /\r?\n/);
    for (let i = length(lines) - 1; i >= 0; i--) {
        if (!trim(lines[i])) continue;
        let parsed = parse_json(trim(lines[i]));
        if (type(parsed) == 'object') return parsed;
    }
    return null;
}
function run_engine(command, value) {
    let line = `/usr/bin/ucode ${q(ENGINE)} ${q(command)}`;
    if (value != null) line += ` ${q(value)}`;
    let executed = capture(line);
    let result = parse_result(executed.output || '');
    if (type(result) != 'object') return { ok: false, error: trim(executed.output || '') || 'firewall engine returned invalid JSON' };
    if (!executed.ok && result.ok === true) return { ok: false, error: 'firewall engine failed' };
    return result;
}
function render(raw) {
    raw = normalize(raw);
    let gid = int(uci_get('run_gid', '23333'));
    let port = int(uci_get('listen_port', '12345'));
    if (gid < 1 || gid > 65535) return { ok: false, error: 'run_gid must be between 1 and 65535' };
    if (port < 1 || port > 65535) return { ok: false, error: 'listen_port must be between 1 and 65535' };
    let compiled = replace(raw, /%gid%/g, `${gid}`);
    compiled = replace(compiled, /%port%/g, `${port}`);
    return { ok: true, raw, compiled };
}
function validate_raw(raw) {
    let rendered = render(raw);
    if (!rendered.ok) return { ok: false, valid: false, error: rendered.error };
    let result = run_engine('firewall-validate', rendered.compiled);
    if (result && result.ok === true) {
        result.config = rendered.raw;
        result.bytes = length(rendered.raw);
    }
    return result;
}
function apply_raw(raw, startup) {
    let rendered = render(raw);
    if (!rendered.ok) return { ok: false, valid: false, error: rendered.error };
    let result = run_engine('firewall-apply', rendered.compiled);
    if (result && result.ok === true) {
        result.config = rendered.raw;
        result.applied_config = rendered.raw;
        result.bytes = length(rendered.raw);
        if (startup) fs.unlink(CANDIDATE);
    }
    return result;
}
function save_raw(raw) {
    let rendered = render(raw);
    if (!rendered.ok) return { ok: false, valid: false, error: rendered.error };
    let checked = run_engine('firewall-validate', rendered.compiled);
    if (!checked || checked.valid !== true) return checked || { ok: false, valid: false, error: 'firewall validation failed' };
    let saved = atomic_write(SOURCE, rendered.raw, 0o600);
    if (!saved.ok) return { ok: false, valid: true, error: saved.error };
    return {
        ok: true,
        valid: true,
        path: SOURCE,
        config: rendered.raw,
        bytes: length(rendered.raw),
        warnings: checked.warnings || []
    };
}
function read_rpc_input(path) {
    path = `${path ?? ''}`;
    if (!match(path, /^\/var\/run\/nftflow\/rpc-[A-Za-z0-9]+\/payload$/)) return { ok: false, error: 'invalid internal RPC input path' };
    let raw = read_text(path);
    return raw == null ? { ok: false, error: 'cannot read internal RPC input file' } : { ok: true, raw };
}
function firewall(mode) {
    mode = mode || 'on';
    if (mode == 'off') return run_engine('firewall', 'off');
    if (mode != 'on') return { ok: false, error: 'firewall mode must be on or off' };
    let source = read_text(SOURCE);
    if (source == null) source = read_text(DEFAULT_SOURCE);
    if (source == null) return { ok: false, error: `cannot read ${SOURCE} or ${DEFAULT_SOURCE}` };
    return apply_raw(source, true);
}
function dispatch(command, args) {
    if (command == 'firewall') return firewall(args[0]);
    if (command == 'firewall-read') return run_engine('firewall-read', null);
    if (command == 'firewall-runtime') return run_engine('firewall-runtime', null);
    if (command == 'firewall-validate') return validate_raw(args[0]);
    if (command == 'firewall-save') return save_raw(args[0]);
    if (command == 'firewall-apply') return apply_raw(args[0], false);
    if (command == 'firewall-validate-file' || command == 'firewall-save-file' || command == 'firewall-apply-file') {
        let input = read_rpc_input(args[0]);
        if (!input.ok) return { ok: false, valid: false, error: input.error };
        if (command == 'firewall-validate-file') return validate_raw(input.raw);
        if (command == 'firewall-save-file') return save_raw(input.raw);
        return apply_raw(input.raw, false);
    }
    return { ok: false, error: `unsupported firewall template command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
