#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0
// Xray YAML frontend implemented in native OpenWrt ucode.

'use strict';

import * as fs from 'fs';

const RUNTIME = '/var/run/nftflow';
const APPLIED_CONFIG = `${RUNTIME}/config.applied.yaml`;
const EDITOR_MAX_BYTES = 32 * 1024;
let sequence = 0;

function q(value) {
    return `'${replace(`${value ?? ''}`, /'/g, `'\\''`)}'`;
}

function capture(command) {
    let proc = fs.popen(`${command} 2>&1`, 'r');
    if (!proc) return { ok: false, output: 'unable to execute command', code: 1 };
    let output = proc.read('all') || '';
    let rc = proc.close();
    let ok = rc === true || rc === 0;
    return { ok, output, code: ok ? 0 : int(rc || 1) };
}

function quiet(command) {
    return system(`${command} >/dev/null 2>&1`) === 0;
}

function mkdirp(path) {
    return quiet(`mkdir -p ${q(path)}`);
}

function read_text(path) {
    return fs.readfile(path);
}

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

function restore_file(path, value) {
    if (value == null) {
        fs.unlink(path);
        return true;
    }
    return atomic_write(path, value, 0o600).ok === true;
}

function uci_get(option, fallback) {
    let result = capture(`/sbin/uci -q get nftflow.main.${option}`);
    let value = trim(result.output || '');
    return result.ok && value ? value : fallback;
}

function main_config() {
    return {
        xray_bin: uci_get('xray_bin', '/usr/bin/xray'),
        config_file: uci_get('config_file', '/etc/nftflow/config.yaml'),
        asset_dir: uci_get('asset_dir', '/usr/share/xray')
    };
}

function normalize(raw) {
    raw = replace(`${raw ?? ''}`, /\r\n/g, '\n');
    raw = replace(raw, /\r/g, '\n');
    if (raw && substr(raw, -1) != '\n') raw += '\n';
    return raw;
}

function prepare_source(raw, path) {
    if (raw == null) return { ok: false, error: `cannot read ${path}` };
    let source = normalize(raw);
    if (length(source) > EDITOR_MAX_BYTES) return { ok: false, error: 'configuration is larger than 32 KiB' };
    if (index(source, '\0') >= 0) return { ok: false, error: 'configuration contains a NUL byte' };
    if (!trim(source)) return { ok: false, error: 'YAML configuration is empty' };
    return { ok: true, source };
}

function validate(raw) {
    let main = main_config();
    let prepared = prepare_source(raw, main.config_file);
    if (!prepared.ok) return { ok: false, valid: false, error: prepared.error };
    if (!quiet(`[ -x ${q(main.xray_bin)} ]`))
        return { ok: false, valid: false, error: `Xray binary is unavailable: ${main.xray_bin}` };
    if (!mkdirp(RUNTIME)) return { ok: false, valid: false, error: `cannot create ${RUNTIME}` };

    sequence++;
    let check_path = `${RUNTIME}/config-check.${pid()}.${time()}.${sequence}.yaml`;
    let saved = atomic_write(check_path, prepared.source, 0o600);
    if (!saved.ok) return { ok: false, valid: false, error: saved.error };

    let command = `XRAY_LOCATION_ASSET=${q(main.asset_dir)} ${q(main.xray_bin)} run -test -format yaml -config ${q(check_path)}`;
    let tested = capture(command);
    fs.unlink(check_path);

    let result = {
        ok: tested.ok,
        valid: tested.ok,
        config: prepared.source,
        bytes: length(prepared.source),
        detail: trim(tested.output || '')
    };
    if (!tested.ok) result.error = 'Xray YAML configuration test failed';
    return result;
}

function read_current() {
    let main = main_config();
    let prepared = prepare_source(read_text(main.config_file), main.config_file);
    if (!prepared.ok) return { ok: false, error: prepared.error, path: main.config_file };
    return {
        ok: true,
        config: prepared.source,
        path: main.config_file,
        bytes: length(prepared.source),
        applied: read_text(APPLIED_CONFIG) != null,
        applied_path: APPLIED_CONFIG
    };
}

function save(raw) {
    let main = main_config();
    let checked = validate(raw);
    if (!checked.valid) return checked;
    let saved = atomic_write(main.config_file, checked.config, 0o600);
    if (!saved.ok) return { ok: false, valid: true, error: saved.error };
    return { ok: true, valid: true, config: checked.config, path: main.config_file, bytes: checked.bytes, detail: checked.detail };
}

function apply(raw) {
    let checked = validate(raw);
    if (!checked.valid) return checked;
    let previous = read_text(APPLIED_CONFIG);
    let saved = atomic_write(APPLIED_CONFIG, checked.config, 0o600);
    if (!saved.ok) return { ok: false, valid: true, error: saved.error };

    let restarted = capture(`NFTFLOW_FORCE_START=1 NFTFLOW_CONFIG_OVERRIDE=${q(APPLIED_CONFIG)} /etc/init.d/nftflow restart`);
    if (!restarted.ok) {
        restore_file(APPLIED_CONFIG, previous);
        return {
            ok: false,
            valid: true,
            error: 'failed to restart NftFlow with the applied YAML configuration',
            detail: trim(restarted.output || '')
        };
    }

    return {
        ok: true,
        valid: true,
        applied: true,
        config: checked.config,
        applied_config: checked.config,
        applied_path: APPLIED_CONFIG,
        detail: trim(restarted.output || '')
    };
}

function read_rpc_input(path) {
    path = `${path ?? ''}`;
    if (!match(path, /^\/var\/run\/nftflow\/rpc-[A-Za-z0-9]+\/payload$/))
        return { ok: false, error: 'invalid internal RPC input path' };
    let raw = read_text(path);
    return raw == null ? { ok: false, error: 'cannot read internal RPC input file' } : { ok: true, raw };
}

function dispatch(command, args) {
    switch (command) {
    case 'config-read':
        return read_current();
    case 'config-validate':
        return validate(args[0]);
    case 'config-save':
        return save(args[0]);
    case 'config-apply':
        return apply(args[0]);
    case 'config-validate-file':
    case 'config-save-file':
    case 'config-apply-file': {
        let input = read_rpc_input(args[0]);
        if (!input.ok) return { ok: false, valid: false, error: input.error };
        if (command == 'config-validate-file') return validate(input.raw);
        if (command == 'config-save-file') return save(input.raw);
        return apply(input.raw);
    }
    default:
        return { ok: false, error: `unsupported config command: ${command}` };
    }
}

let result;
try {
    result = dispatch(ARGV[0] || '', slice(ARGV, 1));
} catch (e) {
    result = { ok: false, error: `${e}` };
}
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
