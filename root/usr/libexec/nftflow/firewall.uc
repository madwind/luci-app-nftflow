#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0
// NftFlow nftables frontend implemented in native OpenWrt ucode.

'use strict';

import * as fs from 'fs';

const RUNTIME = '/var/run/nftflow';
const FIREWALL_SOURCE = '/etc/nftflow/firewall.nft';
const FIREWALL_DEFAULT = '/usr/share/nftflow/defaults/firewall.nft';
const CANDIDATE = `${RUNTIME}/firewall.candidate.nft`;
const APPLIED_SOURCE = `${RUNTIME}/firewall.applied.nft`;
const APPLIED_COMPILED = `${RUNTIME}/firewall.applied.compiled.nft`;
const EDITOR_MAX_BYTES = 32 * 1024;
const OWNED_TABLE = 'nftflow';
const FOLD_THRESHOLD = 10;
let sequence = 0;

function q(value) { return `'${replace(`${value ?? ''}`, /'/g, `'\\''`)}'`; }
function capture(command) {
    let proc = fs.popen(`${command} 2>&1`, 'r');
    if (!proc) return { ok: false, output: 'unable to execute command' };
    let output = proc.read('all') || '';
    let rc = proc.close();
    return { ok: rc === 0, output };
}
function quiet(command) { return system(`${command} >/dev/null 2>&1`) === 0; }
function mkdirp(path) { return quiet(`mkdir -p ${q(path)}`); }
function read_text(path) { return fs.readfile(path); }
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
function restore_file(path, value) {
    if (value == null) { fs.unlink(path); return true; }
    return atomic_write(path, value, 0o600).ok === true;
}
function uci_get(option, fallback) {
    let result = capture(`/sbin/uci -q get nftflow.main.${option}`);
    let value = trim(result.output || '');
    return result.ok && value ? value : fallback;
}
function geoip_path() {
    let configured = trim(uci_get('geoip_file', ''));
    if (configured) return configured;
    let asset_dir = trim(uci_get('asset_dir', '/usr/share/xray')) || '/usr/share/xray';
    return `${asset_dir}/geoip.dat`;
}
function normalize(raw) {
    raw = replace(`${raw ?? ''}`, /\r\n/g, '\n');
    raw = replace(raw, /\r/g, '\n');
    if (raw && substr(raw, -1) != '\n') raw += '\n';
    return raw;
}
function is_space(c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v'; }
function ident_start(c) { return c != null && match(c, /^[A-Za-z_]$/) != null; }
function ident_char(c) { return c != null && match(c, /^[A-Za-z0-9_.-]$/) != null; }
function skip_space(text, pos) { while (pos < length(text) && is_space(substr(text, pos, 1))) pos++; return pos; }
function read_ident(text, pos) {
    pos = skip_space(text, pos);
    if (pos >= length(text) || !ident_start(substr(text, pos, 1))) return null;
    let start = pos++;
    while (pos < length(text) && ident_char(substr(text, pos, 1))) pos++;
    return { value: substr(text, start, pos - start), start, end: pos };
}
function mask(raw) {
    let output = '', quoted = false, escaped = false, comment = false;
    for (let i = 0; i < length(raw); i++) {
        let c = substr(raw, i, 1);
        if (comment) {
            if (c == '\n') { comment = false; output += '\n'; } else output += ' ';
        } else if (quoted) {
            output += c == '\n' ? '\n' : ' ';
            if (escaped) escaped = false;
            else if (c == '\\') escaped = true;
            else if (c == '"') quoted = false;
        } else if (c == '#') {
            comment = true; output += ' ';
        } else if (c == '"') {
            quoted = true; output += ' ';
        } else output += c;
    }
    return output;
}
function matching_brace(text, open_pos, limit) {
    let depth = 0, last = min(limit == null ? length(text) : limit, length(text));
    for (let pos = open_pos; pos < last; pos++) {
        let c = substr(text, pos, 1);
        if (c == '{') depth++;
        else if (c == '}') {
            depth--;
            if (depth == 0) return pos;
            if (depth < 0) return null;
        }
    }
    return null;
}
function parse_elements(text, raw, set_spec) {
    let pos = set_spec.open_position + 1;
    while (pos < set_spec.close_position) {
        pos = skip_space(text, pos);
        if (pos >= set_spec.close_position) break;
        let c = substr(text, pos, 1);
        if (c == '{') {
            let close = matching_brace(text, pos, set_spec.close_position + 1);
            if (close == null) return { ok: false, error: 'unbalanced nft set block' };
            pos = close + 1; continue;
        }
        let word = read_ident(text, pos);
        if (!word) { pos++; continue; }
        pos = word.end;
        if (word.value == 'type') {
            let type_word = read_ident(text, pos);
            if (type_word) { set_spec.type = type_word.value; pos = type_word.end; }
        } else if (word.value == 'elements') {
            let p = skip_space(text, pos);
            if (substr(text, p, 1) == '=') p = skip_space(text, p + 1);
            if (substr(text, p, 1) == '{') {
                let close = matching_brace(text, p, set_spec.close_position + 1);
                if (close == null) return { ok: false, error: 'unbalanced nft set elements block' };
                set_spec.elements_start = word.start;
                set_spec.elements_open = p;
                set_spec.elements_close = close;
                set_spec.elements_body = substr(raw, p + 1, close - p - 1);
                pos = close + 1;
            }
        }
    }
    return { ok: true };
}
function parse_source(raw) {
    raw = `${raw ?? ''}`;
    let text = mask(raw), tables = [], sets = [], pos = 0;
    while (true) {
        pos = skip_space(text, pos);
        if (pos >= length(text)) break;
        let table_kw = read_ident(text, pos);
        if (!table_kw || table_kw.value != 'table' || table_kw.start != pos) return { ok: false, error: 'unsupported top-level nft statement' };
        let family = read_ident(text, table_kw.end);
        let name = family ? read_ident(text, family.end) : null;
        if (!family || !name) return { ok: false, error: 'invalid nft table declaration' };
        let open_pos = skip_space(text, name.end);
        if (substr(text, open_pos, 1) != '{') return { ok: false, error: 'invalid nft table declaration' };
        let close_pos = matching_brace(text, open_pos);
        if (close_pos == null) return { ok: false, error: 'unbalanced nft table block' };
        let table = { family: family.value, name: name.value, key: `${family.value}|${name.value}`, start_position: table_kw.start, open_position: open_pos, close_position: close_pos };
        push(tables, table);

        let scan = open_pos + 1;
        while (scan < close_pos) {
            scan = skip_space(text, scan);
            if (scan >= close_pos) break;
            let c = substr(text, scan, 1);
            if (c == '{') {
                let nested = matching_brace(text, scan, close_pos + 1);
                if (nested == null) return { ok: false, error: 'unbalanced nft table child block' };
                scan = nested + 1; continue;
            }
            let word = read_ident(text, scan);
            if (!word) { scan++; continue; }
            scan = word.end;
            if (word.value != 'set') continue;
            let set_name = read_ident(text, scan);
            if (!set_name) continue;
            let set_open = skip_space(text, set_name.end);
            if (substr(text, set_open, 1) != '{') { scan = set_name.end; continue; }
            let set_close = matching_brace(text, set_open, close_pos + 1);
            if (set_close == null) return { ok: false, error: 'unbalanced nft set block' };
            let spec = {
                table_family: table.family, table_name: table.name, table_key: table.key,
                name: set_name.value, key: `${table.family}|${table.name}|${set_name.value}`,
                start_position: word.start, open_position: set_open, close_position: set_close,
                type: null, elements_start: null, elements_open: null, elements_close: null, elements_body: null
            };
            let parsed_elements = parse_elements(text, raw, spec);
            if (!parsed_elements.ok) return parsed_elements;
            push(sets, spec);
            scan = set_close + 1;
        }
        pos = close_pos + 1;
    }
    return { ok: true, raw, text, tables, sets };
}
function inspect_source(raw) {
    let parsed = parse_source(raw);
    if (!parsed.ok) return parsed;
    if (match(parsed.text, /(^|\s)include(\s|$)/)) return { ok: false, error: 'firewall file must not use include directives' };
    for (let table in parsed.tables)
        if (table.name != OWNED_TABLE) return { ok: false, error: `firewall file may only manage tables named ${OWNED_TABLE}` };

    let macros = [], search_pos = 0;
    while (true) {
        let rel = index(substr(parsed.text, search_pos), '%geoip:');
        if (rel == null || rel < 0) break;
        let start = search_pos + rel;
        let after = start + 7;
        let end_rel = index(substr(parsed.text, after), '%');
        if (end_rel == null || end_rel < 0) return { ok: false, error: 'invalid GeoIP macro; expected %geoip:<tag>%' };
        let finish = after + end_rel + 1;
        let tag = substr(parsed.text, after, finish - after - 1);
        if (!tag || length(tag) > 63 || !match(tag, /^[A-Za-z0-9_-]+$/)) return { ok: false, error: 'invalid GeoIP macro; expected %geoip:<tag>%' };
        let owner = null;
        for (let set_spec in parsed.sets) {
            if (set_spec.elements_open != null && start > set_spec.elements_open && finish - 1 < set_spec.elements_close) { owner = set_spec; break; }
        }
        if (!owner) return { ok: false, error: '%geoip:<tag>% may only be used inside a named set elements block' };
        let family = owner.type == 'ipv4_addr' ? 4 : (owner.type == 'ipv6_addr' ? 6 : null);
        if (!family) return { ok: false, error: '%geoip:<tag>% requires a set of type ipv4_addr or ipv6_addr' };
        owner.has_geoip_macro = true;
        push(macros, { start_position: start, finish_position: finish, tag, family, set: owner });
        search_pos = finish;
    }
    parsed.macros = macros;
    return parsed;
}
function count_elements(body) {
    let n = 0;
    for (let value in split(mask(body || ''), ',')) if (trim(value)) n++;
    return n;
}
function fold_runtime(runtime) {
    let parsed = parse_source(runtime);
    if (!parsed.ok) return runtime;
    for (let i = length(parsed.sets) - 1; i >= 0; i--) {
        let spec = parsed.sets[i];
        if (spec.elements_open == null) continue;
        let count = count_elements(spec.elements_body || '');
        if (count <= FOLD_THRESHOLD) continue;
        let body = spec.elements_body || '';
        let lead = match(body, /^\s*/); lead = lead ? lead[0] : '';
        let tail = match(body, /\s*$/); tail = tail ? tail[0] : '';
        let replacement = (!lead && !tail) ? ` # ${count} entries ` : `${lead}# ${count} entries${tail}`;
        runtime = substr(runtime, 0, spec.elements_open + 1) + replacement + substr(runtime, spec.elements_close);
    }
    return runtime;
}
function read_varint_file(file) {
    let value = 0, multiplier = 1;
    for (let i = 0; i < 10; i++) {
        let raw = file.read(1);
        if (raw == null || length(raw) != 1) return { ok: false, error: 'unexpected end of GeoIP file' };
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
        if (byte == null) return { ok: false, error: 'unexpected end of protobuf message' };
        position++;
        value += (byte % 128) * multiplier;
        if (byte < 128) return { ok: true, value, position };
        multiplier *= 128;
    }
    return { ok: false, error: 'invalid protobuf varint' };
}
function skip_wire(data, position, wire) {
    if (wire == 0) {
        let read = read_varint(data, position); return read.ok ? { ok: true, position: read.position } : read;
    }
    if (wire == 1) return position + 8 <= length(data) ? { ok: true, position: position + 8 } : { ok: false, error: 'truncated protobuf fixed64' };
    if (wire == 2) {
        let read = read_varint(data, position); if (!read.ok) return read;
        let finish = read.position + read.value;
        return finish <= length(data) ? { ok: true, position: finish } : { ok: false, error: 'truncated protobuf bytes' };
    }
    if (wire == 5) return position + 4 <= length(data) ? { ok: true, position: position + 4 } : { ok: false, error: 'truncated protobuf fixed32' };
    return { ok: false, error: `unsupported protobuf wire type ${wire}` };
}
function load_geoip_body(path, tag) {
    let file = fs.open(path, 'r');
    if (!file) return { ok: false, error: `cannot open ${path}`, kind: 'missing_file' };
    let code = uc(tag);
    while (true) {
        let field = file.read(1);
        if (field == null || length(field) == 0) { file.close(); return { ok: false, error: `GeoIP tag not found in ${path}: ${tag}`, kind: 'missing_tag' }; }
        if (ord(field, 0) != 10) { file.close(); return { ok: false, error: 'unsupported GeoIP database structure', kind: 'invalid' }; }
        let length_read = read_varint_file(file);
        if (!length_read.ok) { file.close(); return { ok: false, error: length_read.error, kind: 'invalid' }; }
        let body_length = length_read.value;
        if (body_length < 1 || body_length > 64 * 1024 * 1024) { file.close(); return { ok: false, error: 'invalid GeoIP entry length', kind: 'invalid' }; }
        let prefix_length = min(body_length, length(code) + 2);
        let prefix = file.read(prefix_length);
        if (prefix == null || length(prefix) != prefix_length) { file.close(); return { ok: false, error: 'truncated GeoIP entry', kind: 'invalid' }; }
        let matched = body_length >= length(code) + 2 && ord(prefix, 0) == 10 && ord(prefix, 1) == length(code) && substr(prefix, 2, length(code)) == code;
        let remaining = body_length - prefix_length;
        if (matched) {
            let tail = remaining > 0 ? file.read(remaining) : '';
            file.close();
            if (tail == null || length(tail) != remaining) return { ok: false, error: 'truncated GeoIP entry body', kind: 'invalid' };
            return { ok: true, body: prefix + tail };
        }
        if (remaining > 0 && file.seek(remaining, 1) !== true) { file.close(); return { ok: false, error: 'cannot seek through GeoIP file', kind: 'invalid' }; }
    }
}
function parse_cidr(data) {
    let position = 0, ip = null, prefix = null;
    while (position < length(data)) {
        let key = read_varint(data, position); if (!key.ok) return key; position = key.position;
        let field = int(key.value / 8), wire = key.value % 8;
        if (field == 1 && wire == 2) {
            let size = read_varint(data, position); if (!size.ok) return size;
            let finish = size.position + size.value;
            if (finish > length(data)) return { ok: false, error: 'truncated CIDR address' };
            ip = substr(data, size.position, size.value); position = finish;
        } else if (field == 2 && wire == 0) {
            let value = read_varint(data, position); if (!value.ok) return value;
            prefix = value.value; position = value.position;
        } else {
            let skipped = skip_wire(data, position, wire); if (!skipped.ok) return skipped; position = skipped.position;
        }
    }
    if (ip == null || prefix == null) return { ok: false, error: 'incomplete CIDR entry in GeoIP data' };
    if (length(ip) != 4 && length(ip) != 16) return { ok: false, error: `unsupported GeoIP address length ${length(ip)}` };
    if ((length(ip) == 4 && prefix > 32) || (length(ip) == 16 && prefix > 128)) return { ok: false, error: 'invalid GeoIP CIDR prefix' };
    return { ok: true, ip, prefix, family: length(ip) == 4 ? 4 : 6 };
}
function format_cidr(cidr) {
    if (cidr.family == 4) return sprintf('%d.%d.%d.%d/%d', ord(cidr.ip,0), ord(cidr.ip,1), ord(cidr.ip,2), ord(cidr.ip,3), cidr.prefix);
    let bytes = [];
    for (let i = 0; i < 16; i++) push(bytes, ord(cidr.ip, i));
    return `${arrtoip(bytes)}/${cidr.prefix}`;
}
function load_geoip(path, tag) {
    let loaded = load_geoip_body(path, tag);
    if (!loaded.ok) return loaded;
    let body = loaded.body, position = 0, result = { ok: true, ipv4: [], ipv6: [] };
    while (position < length(body)) {
        let key = read_varint(body, position); if (!key.ok) return { ok: false, error: key.error, kind: 'invalid' }; position = key.position;
        let field = int(key.value / 8), wire = key.value % 8;
        if (field == 2 && wire == 2) {
            let size = read_varint(body, position); if (!size.ok) return { ok: false, error: size.error, kind: 'invalid' };
            let finish = size.position + size.value;
            if (finish > length(body)) return { ok: false, error: 'truncated GeoIP CIDR message', kind: 'invalid' };
            let cidr = parse_cidr(substr(body, size.position, size.value));
            if (!cidr.ok) return { ok: false, error: cidr.error, kind: 'invalid' };
            push(cidr.family == 4 ? result.ipv4 : result.ipv6, format_cidr(cidr));
            position = finish;
        } else if (field == 3 && wire == 0) {
            let reverse = read_varint(body, position); if (!reverse.ok) return { ok: false, error: reverse.error, kind: 'invalid' };
            position = reverse.position;
            if (reverse.value != 0) return { ok: false, error: 'reverse-match GeoIP entries cannot be expanded into nftables elements', kind: 'invalid' };
        } else {
            let skipped = skip_wire(body, position, wire); if (!skipped.ok) return { ok: false, error: skipped.error, kind: 'invalid' }; position = skipped.position;
        }
    }
    return result;
}
function add_warning(warnings, seen, message) { if (!seen[message]) { seen[message] = true; push(warnings, message); } }
function omit_empty_macro(segment, raw, next_position) {
    let without = replace(segment, /,\s*$/, '');
    if (without != segment) return { segment: without, next_position };
    let tail = substr(raw, next_position);
    let comma = match(tail, /^\s*,/);
    if (comma) next_position += length(comma[0]);
    return { segment, next_position };
}
function remove_empty_elements_blocks(raw) {
    let parsed = parse_source(raw);
    if (!parsed.ok) return raw;
    for (let i = length(parsed.sets) - 1; i >= 0; i--) {
        let spec = parsed.sets[i];
        if (spec.elements_start != null && !trim(spec.elements_body || ''))
            raw = substr(raw, 0, spec.elements_start) + substr(raw, spec.elements_close + 1);
    }
    return raw;
}
function compile(raw) {
    let parsed = inspect_source(raw);
    if (!parsed.ok) return parsed;
    let warnings = [], warning_seen = {};
    if (!length(parsed.macros)) return { ok: true, compiled: raw, parsed, warnings };
    let cache = {}, buckets = {}, bucket_order = [], output = '', position = 0, path = geoip_path();
    for (let macro in parsed.macros) {
        let segment = substr(raw, position, macro.start_position - position);
        let next_position = macro.finish_position;
        let key = uc(macro.tag);
        if (cache[key] == null) {
            let data = load_geoip(path, key);
            if (!data.ok) {
                if (data.kind == 'missing_file' || data.kind == 'missing_tag') {
                    cache[key] = { ipv4: [], ipv6: [], missing: true };
                    add_warning(warnings, warning_seen, `geoip:${macro.tag} is unavailable in ${path}; macro ignored`);
                } else return { ok: false, error: data.error };
            } else cache[key] = data;
        }
        let values = macro.family == 4 ? cache[key].ipv4 : cache[key].ipv6;
        if (!length(values)) {
            if (!cache[key].missing) add_warning(warnings, warning_seen, `geoip:${macro.tag} has no IPv${macro.family} CIDRs; macro ignored`);
        } else {
            let bucket = buckets[macro.set.key];
            if (!bucket) {
                bucket = { spec: macro.set, values: [], seen: {} };
                buckets[macro.set.key] = bucket; push(bucket_order, bucket);
            }
            for (let value in values) if (!bucket.seen[value]) { bucket.seen[value] = true; push(bucket.values, value); }
        }
        let omitted = omit_empty_macro(segment, raw, next_position);
        output += omitted.segment; position = omitted.next_position;
    }
    output += substr(raw, position);
    output = remove_empty_elements_blocks(output);
    for (let bucket in bucket_order) {
        if (length(bucket.values)) output += sprintf('\nadd element %s %s %s { %s }\n', bucket.spec.table_family, bucket.spec.table_name, bucket.spec.name, join(', ', bucket.values));
    }
    return { ok: true, compiled: output, parsed, warnings };
}
function table_command(verb, spec) { return `${verb} table ${spec.family} ${spec.name}`; }
function table_active(spec) { return quiet(table_command('nft list', spec)); }
function managed_tables() {
    let result = capture('nft list tables');
    let tables = [], seen = {};
    if (!result.ok) return tables;
    for (let line in split(result.output || '', '\n')) {
        let found = match(trim(line), /^table\s+(\S+)\s+(\S+)$/);
        if (!found || found[2] != OWNED_TABLE) continue;
        let key = `${found[1]} ${found[2]}`;
        if (!seen[key]) { seen[key] = true; push(tables, { family: found[1], name: found[2], key }); }
    }
    return tables;
}
function active_firewall(tables, fold) {
    tables = tables || managed_tables();
    let output = [], missing = [];
    for (let spec in tables) {
        let listed = capture(table_command('nft list', spec));
        if (listed.ok && trim(listed.output || '')) push(output, fold ? fold_runtime(trim(listed.output)) : trim(listed.output));
        else push(missing, spec.key);
    }
    let active = length(output) ? join('\n', output) + '\n' : '# No managed NftFlow nftables tables were found.\n';
    if (!length(tables)) return { active, found: false, missing: [], count: 0 };
    return { active, found: !length(missing), missing, count: length(output) };
}
function transaction(current_tables, desired, desired_tables) {
    let lines = [], targets = {};
    function add_deletes(tables) {
        for (let spec in (tables || [])) {
            let key = `${spec.family} ${spec.name}`;
            if (spec.name == OWNED_TABLE && !targets[key]) {
                targets[key] = true;
                if (table_active(spec)) push(lines, table_command('delete', spec));
            }
        }
    }
    add_deletes(current_tables); add_deletes(desired_tables);
    if (desired) push(lines, desired);
    return join('\n', lines);
}
function run_transaction(content) {
    if (!trim(content || '')) return { ok: true, detail: '' };
    sequence++;
    let path = `${RUNTIME}/firewall-apply.${pid()}.${time()}.${sequence}.nft`;
    let saved = atomic_write(path, content, 0o600);
    if (!saved.ok) return { ok: false, detail: saved.error };
    let checked = capture(`nft --check --file ${q(path)}`);
    if (!checked.ok) { fs.unlink(path); return { ok: false, detail: trim(checked.output || '') }; }
    let applied = capture(`nft --file ${q(path)}`);
    fs.unlink(path);
    return applied.ok ? { ok: true, detail: '' } : { ok: false, detail: trim(applied.output || '') };
}
function validate(raw) {
    raw = `${raw ?? ''}`;
    if (length(raw) > EDITOR_MAX_BYTES) return { ok: false, valid: false, error: 'firewall file is larger than 32 KiB' };
    if (index(raw, '\0') >= 0) return { ok: false, valid: false, error: 'firewall file contains a NUL byte' };
    let source = normalize(raw), built = compile(source);
    if (!built.ok) return { ok: false, valid: false, error: built.error };
    if (!mkdirp(RUNTIME)) return { ok: false, valid: false, error: `cannot create ${RUNTIME}` };
    sequence++;
    let path = `${RUNTIME}/firewall-check.${pid()}.${time()}.${sequence}.nft`;
    let saved = atomic_write(path, built.compiled, 0o600);
    if (!saved.ok) return { ok: false, valid: false, error: saved.error };
    let checked = capture(`nft --check --file ${q(path)}`);
    fs.unlink(path);
    let result = {
        ok: checked.ok, valid: checked.ok, detail: trim(checked.output || ''), config: source, compiled: built.compiled,
        bytes: length(source), tables: built.parsed.tables, geoip_macros: length(built.parsed.macros), warnings: built.warnings
    };
    if (!checked.ok) result.error = 'nftables syntax check failed';
    return result;
}
function read_current() {
    let source = read_text(FIREWALL_SOURCE), using_default = false;
    if (source == null) { source = read_text(FIREWALL_DEFAULT); using_default = true; }
    if (source == null) return { ok: false, error: `cannot read ${FIREWALL_SOURCE} or ${FIREWALL_DEFAULT}`, path: FIREWALL_SOURCE };
    let applied_source = read_text(APPLIED_SOURCE), runtime_tables = managed_tables();
    let state = active_firewall(runtime_tables, true);
    return {
        ok: true, config: source, path: FIREWALL_SOURCE, bytes: length(source), using_default,
        active: state.active, active_found: state.found, missing_tables: state.missing,
        table_count: length(runtime_tables), active_table_count: state.count,
        applied: applied_source != null, applied_config: applied_source || '', candidate_config: read_text(CANDIDATE) || '',
        applied_path: APPLIED_SOURCE, candidate_path: CANDIDATE
    };
}
function save(raw) {
    let checked = validate(raw);
    if (!checked.valid) { delete checked.compiled; return checked; }
    let saved = atomic_write(FIREWALL_SOURCE, checked.config, 0o600);
    return saved.ok ? { ok: true, valid: true, path: FIREWALL_SOURCE, config: checked.config, bytes: length(checked.config), warnings: checked.warnings } : { ok: false, error: saved.error };
}
function apply(raw, write_candidate) {
    let source = normalize(raw);
    if (write_candidate) { let candidate = atomic_write(CANDIDATE, source, 0o600); if (!candidate.ok) return { ok: false, error: candidate.error }; }
    let checked = validate(source);
    if (!checked.valid) { delete checked.compiled; return checked; }
    let desired = checked.compiled, desired_tables = checked.tables;
    let previous_source = read_text(APPLIED_SOURCE), previous_compiled = read_text(APPLIED_COMPILED);
    let current_tables = managed_tables(), current = previous_compiled;
    if (current == null && length(current_tables)) current = active_firewall(current_tables, false).active;
    let loaded = run_transaction(transaction(current_tables, desired, desired_tables));
    if (!loaded.ok) return { ok: false, valid: false, error: 'failed to load configured nftables tables', detail: loaded.detail };
    let runtime_tables = managed_tables(), verified = length(runtime_tables) == length(desired_tables);
    if (verified) for (let spec in desired_tables) if (!table_active(spec)) { verified = false; break; }
    if (!verified) {
        let restored = run_transaction(transaction(runtime_tables, current || '', current_tables));
        let detail = 'runtime table verification failed';
        if (!restored.ok) detail += `; nft rollback failed: ${restored.detail || 'unknown error'}`;
        return { ok: false, valid: false, error: 'configured firewall transaction failed verification', detail };
    }
    let compiled_saved = atomic_write(APPLIED_COMPILED, desired, 0o600);
    let source_saved = compiled_saved.ok ? atomic_write(APPLIED_SOURCE, checked.config, 0o600) : { ok: false, error: null };
    if (!compiled_saved.ok || !source_saved.ok) {
        let restored = run_transaction(transaction(runtime_tables, current || '', current_tables));
        restore_file(APPLIED_COMPILED, previous_compiled); restore_file(APPLIED_SOURCE, previous_source);
        let detail = compiled_saved.error || source_saved.error || 'cannot save applied firewall snapshot';
        if (!restored.ok) detail += `; nft rollback failed: ${restored.detail || 'unknown error'}`;
        return { ok: false, valid: false, error: detail };
    }
    let state = active_firewall(runtime_tables, true);
    return {
        ok: true, applied: true, config: checked.config, applied_config: checked.config,
        active: state.active, active_found: state.found, missing_tables: state.missing,
        table_count: length(runtime_tables), active_table_count: state.count, warnings: checked.warnings
    };
}
function remove_firewall() {
    let current_tables = managed_tables();
    let removed = run_transaction(transaction(current_tables, '', []));
    if (!removed.ok) return { ok: false, error: 'failed to remove configured nftables tables', detail: removed.detail };
    if (length(managed_tables())) return { ok: false, error: 'some NftFlow nftables tables are still active' };
    fs.unlink(CANDIDATE); fs.unlink(APPLIED_SOURCE); fs.unlink(APPLIED_COMPILED);
    return { ok: true, enabled: false, active: '# No active NftFlow nftables objects were found.\n' };
}
function read_rpc_input(path) {
    path = `${path ?? ''}`;
    if (!match(path, /^\/var\/run\/nftflow\/rpc-[A-Za-z0-9]+\/payload$/)) return { ok: false, error: 'invalid internal RPC input path' };
    let raw = read_text(path);
    return raw == null ? { ok: false, error: 'cannot read internal RPC input file' } : { ok: true, raw };
}
function dispatch(command, args) {
    if (command == 'firewall') {
        let mode = args[0] || 'on';
        if (mode == 'off') return remove_firewall();
        if (mode != 'on') return { ok: false, error: 'firewall mode must be on or off' };
        let source = read_text(FIREWALL_SOURCE);
        if (source == null) source = read_text(FIREWALL_DEFAULT);
        if (source == null) return { ok: false, error: `cannot read ${FIREWALL_SOURCE} or ${FIREWALL_DEFAULT}` };
        return apply(source, false);
    }
    if (command == 'firewall-read') return read_current();
    if (command == 'firewall-validate') { let result = validate(args[0]); delete result.compiled; return result; }
    if (command == 'firewall-save') return save(args[0]);
    if (command == 'firewall-apply') return apply(args[0], true);
    if (command == 'firewall-validate-file' || command == 'firewall-save-file' || command == 'firewall-apply-file') {
        let input = read_rpc_input(args[0]); if (!input.ok) return { ok: false, valid: false, error: input.error };
        if (command == 'firewall-validate-file') { let result = validate(input.raw); delete result.compiled; return result; }
        if (command == 'firewall-save-file') return save(input.raw);
        return apply(input.raw, true);
    }
    return { ok: false, error: `unsupported firewall command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
