#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const RUNTIME = '/var/run/nftflow';
const FIREWALL_SOURCE = '/etc/nftflow/firewall.nft';
const DEFAULT_SOURCE = '/usr/share/nftflow/defaults/firewall.nft';
const APPLIED_SOURCE = `${RUNTIME}/firewall.applied.nft`;
const OWNED_TABLE = 'nftflow';
const FOLD_THRESHOLD = 10;
let sequence = 0;
let uci = cursor();

function q(value) { return `'${replace(`${value ?? ''}`, /'/g, `'\\''`)}'`; }
function nft(command) {
    let proc = fs.popen(`/usr/sbin/nft ${command} 2>&1`, 'r');
    if (!proc) return { ok: false, output: 'unable to execute nft' };
    let output = proc.read('all') || '';
    let rc = proc.close();
    return { ok: rc === 0, output };
}
function quiet(command) { return system(`${command} >/dev/null 2>&1`) === 0; }
function mkdirp(path) { return quiet(`mkdir -p ${q(path)}`); }
function read_text(path) { return fs.readfile(path); }
function atomic_write(path, value, mode) {
    let parent = fs.dirname(path) || '.';
    if (!mkdirp(parent)) return { ok: false, error: `cannot create ${parent}` };
    sequence++;
    let temporary = `${path}.tmp.${time()}.${sequence}`;
    let written = fs.writefile(temporary, value);
    if (written == null || written != length(value)) { fs.unlink(temporary); return { ok: false, error: `cannot write temporary file for ${path}` }; }
    if (mode != null && fs.chmod(temporary, mode) !== true) { fs.unlink(temporary); return { ok: false, error: `cannot chmod temporary file for ${path}` }; }
    if (fs.rename(temporary, path) !== true) { fs.unlink(temporary); return { ok: false, error: `cannot replace ${path}` }; }
    if (mode != null) fs.chmod(path, mode);
    return { ok: true };
}
function normalize(raw) {
    raw = replace(`${raw ?? ''}`, /\r\n/g, '\n');
    raw = replace(raw, /\r/g, '\n');
    if (raw && substr(raw, -1) != '\n') raw += '\n';
    return raw;
}
function default_source() {
    let raw = read_text(DEFAULT_SOURCE);
    return raw == null
        ? { ok: false, error: `cannot read ${DEFAULT_SOURCE}` }
        : { ok: true, config: normalize(raw), path: DEFAULT_SOURCE, customized: false };
}
function effective_source() {
    let raw = read_text(FIREWALL_SOURCE);
    if (raw != null)
        return { ok: true, config: raw, path: FIREWALL_SOURCE, customized: true };
    return default_source();
}
function render_template(raw) {
    let source = normalize(raw);
    let value = null;
    try { value = uci.get('nftflow', 'main', 'run_gid'); } catch (e) {}
    let gid = int(value || 23333);
    if (gid < 1 || gid > 65535) return { ok: false, error: 'run_gid must be between 1 and 65535' };
    return { ok: true, source, rendered: replace(source, /%gid%/g, `${gid}`) };
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
function matching_brace(text, open_pos) {
    let depth = 0;
    for (let pos = open_pos; pos < length(text); pos++) {
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
function inspect_source(raw) {
    let text = mask(raw), tables = [], pos = 0;
    if (match(text, /(^|\s)include(\s|$)/)) return { ok: false, error: 'firewall file must not use include directives' };
    while (true) {
        pos = skip_space(text, pos);
        if (pos >= length(text)) break;
        let table_kw = read_ident(text, pos);
        if (!table_kw || table_kw.value != 'table' || table_kw.start != pos) return { ok: false, error: 'unsupported top-level nft statement' };
        let family = read_ident(text, table_kw.end);
        let name = family ? read_ident(text, family.end) : null;
        if (!family || !name) return { ok: false, error: 'invalid nft table declaration' };
        if (name.value != OWNED_TABLE) return { ok: false, error: `firewall file may only manage tables named ${OWNED_TABLE}` };
        let open_pos = skip_space(text, name.end);
        if (substr(text, open_pos, 1) != '{') return { ok: false, error: 'invalid nft table declaration' };
        let close_pos = matching_brace(text, open_pos);
        if (close_pos == null) return { ok: false, error: 'unbalanced nft table block' };
        push(tables, { family: family.value, name: name.value });
        pos = close_pos + 1;
    }
    return { ok: true, tables };
}
function runtime_token_visible(raw, position) {
    let line = position, quote = null, escaped = false;
    while (line > 0 && substr(raw, line - 1, 1) != '\n') line--;
    for (let i = line; i < position; i++) {
        let c = substr(raw, i, 1);
        if (quote != null) {
            if (escaped) escaped = false;
            else if (c == '\\') escaped = true;
            else if (c == quote) quote = null;
            continue;
        }
        if (c == '#') return false;
        if (c == '"' || c == "'") quote = c;
    }
    return quote == null;
}
function scan_runtime_elements(raw, open_position) {
    let depth = 1, count = 0, has_item = false;
    let quote = null, escaped = false, comment = false;
    for (let pos = open_position + 1; pos < length(raw); pos++) {
        let c = substr(raw, pos, 1);
        if (comment) { if (c == '\n') comment = false; continue; }
        if (quote != null) {
            if (depth == 1) has_item = true;
            if (escaped) escaped = false;
            else if (c == '\\') escaped = true;
            else if (c == quote) quote = null;
            continue;
        }
        if (c == '#') { comment = true; continue; }
        if (c == '"' || c == "'") { quote = c; if (depth == 1) has_item = true; continue; }
        if (c == '{') { if (depth == 1) has_item = true; depth++; continue; }
        if (c == '}') {
            depth--;
            if (depth == 0) { if (has_item) count++; return { ok: true, close: pos, count }; }
            if (depth < 0) return { ok: false };
            continue;
        }
        if (depth != 1) continue;
        if (c == ',') { if (has_item) count++; has_item = false; continue; }
        if (!is_space(c)) has_item = true;
    }
    return { ok: false };
}
function fold_runtime(runtime) {
    runtime = `${runtime ?? ''}`;
    let replacements = [], search_position = 0;
    while (search_position < length(runtime)) {
        let rel = index(substr(runtime, search_position), 'elements');
        if (rel == null || rel < 0) break;
        let start = search_position + rel, finish = start + 8;
        search_position = finish;
        let before = start > 0 ? substr(runtime, start - 1, 1) : '';
        let after = finish < length(runtime) ? substr(runtime, finish, 1) : '';
        if ((before && ident_char(before)) || (after && ident_char(after)) || !runtime_token_visible(runtime, start)) continue;
        let open = skip_space(runtime, finish);
        if (substr(runtime, open, 1) != '=') continue;
        open = skip_space(runtime, open + 1);
        if (substr(runtime, open, 1) != '{') continue;
        let scanned = scan_runtime_elements(runtime, open);
        if (!scanned.ok) return runtime;
        if (scanned.count > FOLD_THRESHOLD) push(replacements, { open, close: scanned.close, count: scanned.count });
        search_position = scanned.close + 1;
    }
    for (let i = length(replacements) - 1; i >= 0; i--) {
        let replacement = replacements[i];
        runtime = substr(runtime, 0, replacement.open + 1) + ` # ${replacement.count} entries ` + substr(runtime, replacement.close);
    }
    return runtime;
}
function managed_tables() {
    let result = nft('list tables');
    if (!result.ok) return { ok: false, error: trim(result.output || '') || 'unable to list nftables tables' };
    let tables = [], seen = {};
    for (let line in split(result.output || '', '\n')) {
        let found = match(trim(line), /^table\s+(\S+)\s+(\S+)$/);
        if (!found || found[2] != OWNED_TABLE) continue;
        let key = `${found[1]} ${found[2]}`;
        if (!seen[key]) { seen[key] = true; push(tables, { family: found[1], name: found[2], key }); }
    }
    return { ok: true, tables };
}
function runtime_current() {
    let managed = managed_tables();
    if (!managed.ok) return managed;
    let output = [], output_full = [];
    for (let spec in managed.tables) {
        let listed = nft(`list table ${spec.family} ${spec.name}`);
        if (!listed.ok) return { ok: false, error: trim(listed.output || '') || `unable to read nftables table ${spec.family} ${spec.name}` };
        let current = trim(listed.output || '');
        if (current) {
            push(output, fold_runtime(current));
            push(output_full, current);
        }
    }
    let active = length(output) ? join('\n', output) + '\n' : '# No managed NftFlow nftables tables were found.\n';
    let active_full = length(output_full) ? join('\n', output_full) + '\n' : active;
    return { ok: true, active, active_full, firewall_active: length(managed.tables) > 0 };
}
function transaction(current_tables, desired) {
    let lines = [];
    for (let spec in (current_tables || [])) push(lines, `delete table ${spec.family} ${spec.name}`);
    if (desired) push(lines, desired);
    return join('\n', lines);
}
function run_transaction(content) {
    if (!trim(content || '')) return { ok: true, detail: '' };
    sequence++;
    let path = `${RUNTIME}/firewall-apply.${time()}.${sequence}.nft`;
    let saved = atomic_write(path, content, 0o600);
    if (!saved.ok) return { ok: false, detail: saved.error };
    let checked = nft(`--check --file ${q(path)}`);
    if (!checked.ok) { fs.unlink(path); return { ok: false, detail: trim(checked.output || '') }; }
    let applied = nft(`--file ${q(path)}`);
    fs.unlink(path);
    return applied.ok ? { ok: true, detail: '' } : { ok: false, detail: trim(applied.output || '') };
}
function validate(raw) {
    raw = `${raw ?? ''}`;
    if (index(raw, '\0') >= 0) return { ok: false, valid: false, error: 'firewall file contains a NUL byte' };
    let template = render_template(raw);
    if (!template.ok) return { ok: false, valid: false, error: template.error };
    let inspected = inspect_source(template.rendered);
    if (!inspected.ok) return { ok: false, valid: false, error: inspected.error };
    sequence++;
    let path = `${RUNTIME}/firewall-check.${time()}.${sequence}.nft`;
    let saved = atomic_write(path, template.rendered, 0o600);
    if (!saved.ok) return { ok: false, valid: false, error: saved.error };
    let checked = nft(`--check --file ${q(path)}`);
    fs.unlink(path);
    let detail = trim(checked.output || '');
    if (!checked.ok) return { ok: false, valid: false, error: 'nftables syntax check failed', detail };
    return { ok: true, valid: true, config: template.source, compiled: template.rendered };
}
function save(raw) {
    let checked = validate(raw);
    if (!checked.valid) { delete checked.compiled; return checked; }
    let fallback = default_source();
    if (!fallback.ok) return fallback;
    if (checked.config == fallback.config) {
        fs.unlink(FIREWALL_SOURCE);
        return { ok: true, valid: true, config: fallback.config, customized: false };
    }
    let saved = atomic_write(FIREWALL_SOURCE, checked.config, 0o600);
    return saved.ok
        ? { ok: true, valid: true, config: checked.config, customized: true }
        : { ok: false, error: saved.error };
}
function fail_open(error, detail) {
    let errors = [];
    if (detail) push(errors, detail);
    let managed = managed_tables();
    if (!managed.ok) push(errors, `firewall cleanup failed: ${managed.error}`);
    else {
        let removed = run_transaction(transaction(managed.tables, ''));
        if (!removed.ok) push(errors, `firewall cleanup failed: ${removed.detail || 'unknown error'}`);
    }
    fs.unlink(APPLIED_SOURCE);
    return { ok: false, valid: false, error, detail: join('; ', errors) };
}
function apply(raw) {
    let checked = validate(raw);
    if (!checked.valid) { delete checked.compiled; return checked; }
    let managed = managed_tables();
    if (!managed.ok) return { ok: false, valid: false, error: managed.error };
    let loaded = run_transaction(transaction(managed.tables, checked.compiled));
    if (!loaded.ok) return fail_open('failed to load configured nftables tables', loaded.detail);
    let source_saved = atomic_write(APPLIED_SOURCE, checked.config, 0o600);
    if (!source_saved.ok) return fail_open(source_saved.error || 'cannot save applied firewall snapshot', 'nftables runtime was removed after the snapshot save failed');
    return { ok: true, applied: true, config: checked.config };
}
function remove_firewall() {
    let managed = managed_tables();
    if (!managed.ok) return { ok: false, error: managed.error };
    let removed = run_transaction(transaction(managed.tables, ''));
    if (!removed.ok) return { ok: false, error: 'failed to remove configured nftables tables', detail: removed.detail };
    fs.unlink(APPLIED_SOURCE);
    return { ok: true, enabled: false };
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
        let source = effective_source();
        if (!source.ok) return source;
        return apply(source.config);
    }
    if (command == 'firewall-runtime') return runtime_current();
    if (command == 'firewall-save-file') {
        let input = read_rpc_input(args[0]);
        if (!input.ok) return { ok: false, valid: false, error: input.error };
        return save(input.raw);
    }
    return { ok: false, error: `unsupported firewall command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
