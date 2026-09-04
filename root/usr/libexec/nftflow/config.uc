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
    let asset_dir = uci_get('asset_dir', '/usr/share/xray');
    return {
        config_file: uci_get('config_file', '/etc/nftflow/config.yaml'),
        asset_dir,
        geoip_file: uci_get('geoip_file', `${asset_dir}/geoip.dat`),
        geosite_file: uci_get('geosite_file', `${asset_dir}/geosite.dat`)
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

function strip_yaml_comment(line) {
    let single = false, double = false, escaped = false;
    for (let i = 0; i < length(line); i++) {
        let c = substr(line, i, 1);
        if (double) {
            if (escaped) escaped = false;
            else if (c == '\\') escaped = true;
            else if (c == '"') double = false;
            continue;
        }
        if (single) {
            if (c == "'") {
                if (substr(line, i + 1, 1) == "'") i++;
                else single = false;
            }
            continue;
        }
        if (c == '#') return substr(line, 0, i);
        if (c == '"') double = true;
        else if (c == "'") single = true;
    }
    return line;
}

function geodata_tag_char(c) {
    return c != null && match(c, /^[A-Za-z0-9_-]$/) != null;
}

function collect_geodata_refs(source) {
    let refs = { geoip: {}, geosite: {} };
    for (let source_line in split(source, '\n')) {
        let line = strip_yaml_comment(source_line);
        let lower = lc(line);
        for (let kind in [ 'geoip', 'geosite' ]) {
            let needle = `${kind}:`, position = 0;
            while (position < length(line)) {
                let rel = index(substr(lower, position), needle);
                if (rel == null || rel < 0) break;
                let start = position + rel;
                let previous = start > 0 ? substr(lower, start - 1, 1) : '';
                if (previous && match(previous, /^[A-Za-z0-9_]$/)) {
                    position = start + length(needle);
                    continue;
                }
                let tag_start = start + length(needle), finish = tag_start;
                while (finish < length(line) && geodata_tag_char(substr(line, finish, 1))) finish++;
                if (finish > tag_start) {
                    let tag = substr(line, tag_start, finish - tag_start);
                    refs[kind][uc(tag)] = tag;
                }
                position = finish > tag_start ? finish : tag_start;
            }
        }
    }
    return refs;
}

function read_varint_file(file) {
    let value = 0, multiplier = 1;
    for (let i = 0; i < 10; i++) {
        let raw = file.read(1);
        if (raw == null || length(raw) != 1) return { ok: false, error: 'unexpected end of GeoData file' };
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
        if (byte == null) return { ok: false, error: 'truncated GeoData entry' };
        position++;
        value += (byte % 128) * multiplier;
        if (byte < 128) return { ok: true, value, position };
        multiplier *= 128;
    }
    return { ok: false, error: 'invalid protobuf varint' };
}

function validate_geodata_file(path, label, refs) {
    let requested = [], pending = {};
    for (let code, original in refs) {
        pending[code] = original;
        push(requested, code);
    }
    if (!length(requested)) return { ok: true };

    let file = fs.open(path, 'r');
    if (!file) return { ok: false, error: `${label} data file is missing: ${path}` };

    while (length(requested)) {
        let field = file.read(1);
        if (field == null || length(field) == 0) break;
        if (ord(field, 0) != 10) {
            file.close();
            return { ok: false, error: `${label} data file has an unsupported structure: ${path}` };
        }

        let size = read_varint_file(file);
        if (!size.ok) {
            file.close();
            return { ok: false, error: `${label} data file is invalid: ${size.error}` };
        }
        if (size.value < 1 || size.value > 64 * 1024 * 1024) {
            file.close();
            return { ok: false, error: `${label} data file contains an invalid entry length` };
        }

        let prefix_length = min(size.value, 256);
        let prefix = file.read(prefix_length);
        if (prefix == null || length(prefix) != prefix_length) {
            file.close();
            return { ok: false, error: `${label} data file is truncated: ${path}` };
        }

        let code = null;
        if (length(prefix) > 1 && ord(prefix, 0) == 10) {
            let code_size = read_varint(prefix, 1);
            if (code_size.ok && code_size.value > 0 && code_size.position + code_size.value <= length(prefix))
                code = uc(substr(prefix, code_size.position, code_size.value));
        }

        if (code != null && pending[code] != null) {
            delete pending[code];
            let remaining = [];
            for (let wanted in requested) if (wanted != code) push(remaining, wanted);
            requested = remaining;
        }

        let rest = size.value - prefix_length;
        if (rest > 0 && file.seek(rest, 1) !== true) {
            file.close();
            return { ok: false, error: `cannot seek through ${label} data file: ${path}` };
        }
    }

    file.close();
    if (!length(requested)) return { ok: true };

    let missing = [];
    for (let code in requested) push(missing, `${lc(label)}:${pending[code]}`);
    return { ok: false, error: `${label} tags are unavailable: ${join(', ', missing)}` };
}

function validate_geodata_refs(source, main) {
    let refs = collect_geodata_refs(source);
    let checked = validate_geodata_file(main.geoip_file, 'GeoIP', refs.geoip);
    if (!checked.ok) return checked;
    checked = validate_geodata_file(main.geosite_file, 'GeoSite', refs.geosite);
    if (!checked.ok) return checked;
    return { ok: true };
}

function validate(raw) {
    let main = main_config();
    let prepared = prepare_source(raw, main.config_file);
    if (!prepared.ok) return { ok: false, valid: false, error: prepared.error };

    let geodata = validate_geodata_refs(prepared.source, main);
    if (!geodata.ok) return { ok: false, valid: false, error: geodata.error };

    return {
        ok: true,
        valid: true,
        config: prepared.source,
        bytes: length(prepared.source),
        detail: ''
    };
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
