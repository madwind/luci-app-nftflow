#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0
// NftFlow policy routing controller implemented in native OpenWrt ucode.

'use strict';

import * as fs from 'fs';

const SOURCE = '/etc/nftflow/routing.conf';
const RUNTIME = '/var/run/nftflow';
const APPLIED = `${RUNTIME}/routing.applied.conf`;
const CANDIDATE = `${RUNTIME}/routing.candidate.conf`;
const LEGACY_OWNERSHIP = `${RUNTIME}/routing.ownership.json`;
const MAX_BYTES = 32 * 1024;
let sequence = 0;

function q(value) { return `'${replace(`${value ?? ''}`, /'/g, `'\\''`)}'`; }
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
function atomic_write(path, value) {
    if (!mkdirp(fs.dirname(path) || '.')) return { ok: false, error: `cannot create ${fs.dirname(path) || '.'}` };
    sequence++;
    let temporary = `${path}.tmp.${pid()}.${time()}.${sequence}`;
    let written = fs.writefile(temporary, value);
    if (written == null || written != length(value)) { fs.unlink(temporary); return { ok: false, error: 'cannot write temporary file' }; }
    fs.chmod(temporary, 0o600);
    if (fs.rename(temporary, path) !== true) { fs.unlink(temporary); return { ok: false, error: `cannot replace ${path}` }; }
    return { ok: true };
}
function num(value) {
    if (value == null) return null;
    let text = `${value}`;
    if (match(text, /^0[xX][0-9A-Fa-f]+$/)) return int(substr(text, 2), 16);
    let n = +text;
    return n == n ? n : null;
}
function normalized_prefix(family, prefix) {
    if (prefix == 'default') return family == '4' ? '0.0.0.0/0' : '::/0';
    return prefix;
}

function parse_config(raw) {
    raw = `${raw ?? ''}`;
    if (length(raw) > MAX_BYTES) return { ok: false, error: 'routing file is larger than 32 KiB' };
    if (index(raw, '\0') >= 0) return { ok: false, error: 'routing file contains a NUL byte' };
    raw = replace(replace(raw, /\r\n/g, '\n'), /\r/g, '\n');

    let routes = {}, rules = {}, lines = [];
    for (let source_line in split(raw, '\n')) {
        let line = trim(source_line);
        if (!line || substr(line, 0, 1) == '#') continue;

        let route = match(line, /^ip\s+-([46])\s+route\s+replace\s+local\s+(\S+)\s+dev\s+lo\s+table\s+(\d+)$/);
        if (route) {
            let family = route[1];
            if (routes[family]) return { ok: false, error: `duplicate IPv${family} route` };
            routes[family] = { family, prefix: route[2], table: int(route[3]), route: line };
            push(lines, line);
            continue;
        }

        let rule = match(line, /^ip\s+-([46])\s+rule\s+add\s+fwmark\s+([^\/\s]+)\/([^\s]+)\s+lookup\s+(\d+)$/);
        if (!rule) return { ok: false, error: `unsupported routing command: ${line}` };
        let family = rule[1];
        if (rules[family]) return { ok: false, error: `duplicate IPv${family} rule` };
        let mark = num(rule[2]), mask = num(rule[3]), table = int(rule[4]);
        if (mark == null || mask == null || mark < 1 || mask < 1 || mark > 0xffffffff || mask > 0xffffffff)
            return { ok: false, error: 'invalid firewall mark or mask' };
        rules[family] = { family, mark, mask, table, rule: line };
        push(lines, line);
    }

    if (!routes['4'] || !rules['4']) return { ok: false, error: 'routing file must declare IPv4 route and rule' };
    if (!!routes['6'] != !!rules['6']) return { ok: false, error: 'routing file must declare both IPv6 route and rule' };

    let state = { normalized: join('\n', lines) + '\n', commands: lines, route_commands: [], rule_commands: [], ipv6_enabled: !!routes['6'] };
    for (let family in [ '4', '6' ]) {
        if (!routes[family]) continue;
        if (routes[family].table != rules[family].table) return { ok: false, error: `IPv${family} route and rule must use the same table` };
        let spec = {
            family,
            prefix: routes[family].prefix,
            table: routes[family].table,
            mark: rules[family].mark,
            mask: rules[family].mask,
            route: routes[family].route,
            rule: rules[family].rule
        };
        state[`ipv${family}`] = spec;
        push(state.route_commands, spec.route);
        push(state.rule_commands, spec.rule);
    }
    state.mark = state.ipv4.mark;
    state.mask = state.ipv4.mask;
    state.table = state.ipv4.table;
    return { ok: true, state };
}

function rule_present(spec) {
    let result = capture(`ip -${spec.family} rule show`);
    if (!result.ok) return false;
    for (let source_line in split(result.output || '', '\n')) {
        let body = trim(replace(source_line, /^\s*\d+:\s*/, ''));
        let found = match(body, /^from\s+all\s+fwmark\s+(\S+)\s+[Ll]ookup\s+(\S+)$/);
        if (!found) continue;
        let markmask = split(found[1], '/');
        let mark = num(markmask[0]);
        let mask = num(length(markmask) > 1 ? markmask[1] : '0xffffffff');
        if (mark == spec.mark && mask == spec.mask && num(found[2]) == spec.table) return true;
    }
    return false;
}

function route_state(spec) {
    let result = capture(`ip -${spec.family} route show table ${spec.table}`);
    if (!result.ok) return { exact: false, conflict: false };
    let expected = normalized_prefix(spec.family, spec.prefix);
    let exact = false, conflict = false;
    for (let line in split(result.output || '', '\n')) {
        let fields = split(trim(line), /\s+/);
        if (length(fields) < 2) continue;
        if (normalized_prefix(spec.family, fields[1]) != expected) continue;
        if (fields[0] == 'local' && match(line, /\sdev\s+lo(?:\s|$)/)) exact = true;
        else conflict = true;
    }
    return { exact, conflict };
}

function active(spec) { return route_state(spec).exact && rule_present(spec); }
function same_route_spec(a, b) {
    return !!a && !!b && a.family == b.family && normalized_prefix(a.family, a.prefix) == normalized_prefix(b.family, b.prefix) && a.table == b.table;
}
function delete_route(spec) { return quiet(`ip -${spec.family} route del local ${q(spec.prefix)} dev lo table ${spec.table}`); }
function delete_rules(spec) {
    let count = 0;
    while (rule_present(spec)) {
        if (count++ >= 64 || !quiet(`ip -${spec.family} rule del fwmark ${spec.mark}/${spec.mask} lookup ${spec.table}`)) return false;
    }
    return true;
}
function ensure_route(spec) {
    let current = route_state(spec);
    if (current.conflict) return { ok: false, error: `refusing to replace existing IPv${spec.family} route ${spec.prefix}` };
    if (!current.exact && !quiet(`ip -${spec.family} route add local ${q(spec.prefix)} dev lo table ${spec.table}`))
        return { ok: false, error: `failed to add IPv${spec.family} route` };
    if (!route_state(spec).exact) return { ok: false, error: `IPv${spec.family} route verification failed` };
    return { ok: true };
}
function ensure_rule(spec) {
    if (!rule_present(spec) && !quiet(spec.rule)) return { ok: false, error: `failed to add IPv${spec.family} rule` };
    if (!rule_present(spec)) return { ok: false, error: `IPv${spec.family} rule verification failed` };
    return { ok: true };
}
function remove_state(state, keep_routes) {
    if (!state) return { ok: true };
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (spec && rule_present(spec) && !delete_rules(spec)) return { ok: false, error: `failed to delete IPv${family} rule` };
    }
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        let keep = keep_routes ? keep_routes[`ipv${family}`] : null;
        if (spec && !same_route_spec(spec, keep) && route_state(spec).exact && !delete_route(spec))
            return { ok: false, error: `failed to delete IPv${family} route` };
    }
    return { ok: true };
}
function install_state(state) {
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (!spec) continue;
        let result = ensure_route(spec);
        if (!result.ok) return result;
    }
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (!spec) continue;
        let result = ensure_rule(spec);
        if (!result.ok) return result;
    }
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (spec && !active(spec)) return { ok: false, error: `IPv${family} policy route verification failed` };
    }
    return { ok: true };
}
function rollback(previous, current) {
    let errors = [];
    let result = remove_state(current, previous);
    if (!result.ok) push(errors, result.error);
    if (previous) {
        result = install_state(previous);
        if (!result.ok) push(errors, result.error);
    }
    return { ok: length(errors) == 0, error: join('; ', errors) };
}
function state_status(state) {
    let ipv4 = !!state && !!state.ipv4 && active(state.ipv4);
    let ipv6 = !!state && !!state.ipv6 && active(state.ipv6);
    return { active: ipv4 && (!state || !state.ipv6_enabled || ipv6), ipv4, ipv6 };
}
function runtime_text(state) {
    if (!state) return '# No active policy routing commands are installed.\n';
    let output = [];
    for (let family in [ '4', '6' ]) {
        let spec = state[`ipv${family}`];
        if (!spec) continue;
        let rules = capture(`ip -${family} rule show`).output || '';
        let routes = capture(`ip -${family} route show table ${spec.table}`).output || '';
        push(output, `# ip -${family} rule show\n${rules}`);
        push(output, `# ip -${family} route show table ${spec.table}\n${routes}`);
    }
    return join('\n\n', output) + '\n';
}

function validate(raw) {
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, valid: false, error: parsed.error };
    let state = parsed.state;
    return {
        ok: true, valid: true, config: state.normalized, bytes: length(state.normalized), commands: state.commands,
        route_commands: state.route_commands, rule_commands: state.rule_commands, ipv6_enabled: state.ipv6_enabled,
        firewall_mark: state.mark, routing_table: state.table
    };
}
function read_current() {
    let raw = read_text(SOURCE);
    if (raw == null) return { ok: false, error: `cannot read ${SOURCE}`, path: SOURCE };
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, error: parsed.error, path: SOURCE };
    let state = parsed.state;
    let applied_raw = read_text(APPLIED);
    let applied = applied_raw ? parse_config(applied_raw) : null;
    let runtime_state = applied && applied.ok ? applied.state : state;
    let status = state_status(runtime_state);
    return {
        ok: true, path: SOURCE, config: state.normalized, bytes: length(state.normalized), commands: state.commands,
        route_commands: state.route_commands, rule_commands: state.rule_commands, active: runtime_text(runtime_state),
        route_active: status.active, route_ipv4: status.ipv4, route_ipv6: status.ipv6,
        ipv6_enabled: state.ipv6_enabled, firewall_mark: state.mark, routing_table: state.table,
        applied_config: applied_raw || '', applied_path: APPLIED, candidate_path: CANDIDATE
    };
}
function save(raw) {
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, valid: false, error: parsed.error };
    let result = atomic_write(SOURCE, parsed.state.normalized);
    return result.ok
        ? { ok: true, valid: true, path: SOURCE, config: parsed.state.normalized, bytes: length(parsed.state.normalized) }
        : { ok: false, valid: true, error: result.error };
}
function apply(raw, candidate) {
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, valid: false, error: parsed.error };
    let state = parsed.state;
    if (candidate) {
        let saved = atomic_write(CANDIDATE, state.normalized);
        if (!saved.ok) return { ok: false, error: saved.error };
    }

    let previous_raw = read_text(APPLIED);
    let previous = null;
    if (previous_raw) {
        let checked = parse_config(previous_raw);
        if (!checked.ok) return { ok: false, error: `invalid applied routing state: ${checked.error}` };
        previous = checked.state;
    }

    if (previous && previous.normalized != state.normalized) {
        let removed = remove_state(previous, state);
        if (!removed.ok) {
            let restored = install_state(previous);
            if (!restored.ok) removed.error += `; rollback failed: ${restored.error}`;
            return removed;
        }
    }

    let installed = install_state(state);
    if (!installed.ok) {
        let restored = rollback(previous, state);
        if (!restored.ok) installed.error += `; rollback failed: ${restored.error}`;
        return installed;
    }

    let saved = atomic_write(APPLIED, state.normalized);
    if (!saved.ok) {
        let restored = rollback(previous, state);
        let error = saved.error;
        if (!restored.ok) error += `; rollback failed: ${restored.error}`;
        return { ok: false, error };
    }
    fs.unlink(LEGACY_OWNERSHIP);
    let status = state_status(state);
    return {
        ok: true, valid: true, applied: true, config: state.normalized, applied_config: state.normalized,
        routing_active: runtime_text(state), route_active: status.active, route_ipv4: status.ipv4, route_ipv6: status.ipv6,
        ipv6_enabled: state.ipv6_enabled, policy_route_commands: state.commands, route_commands: state.route_commands,
        rule_commands: state.rule_commands, firewall_mark: state.mark, routing_table: state.table
    };
}
function remove_routes() {
    let raw = read_text(APPLIED) || read_text(SOURCE);
    if (!raw) { fs.unlink(CANDIDATE); fs.unlink(LEGACY_OWNERSHIP); return { ok: true, route_active: false }; }
    let parsed = parse_config(raw);
    if (!parsed.ok) return { ok: false, error: parsed.error };
    let removed = remove_state(parsed.state, null);
    if (!removed.ok) return removed;
    fs.unlink(APPLIED); fs.unlink(CANDIDATE); fs.unlink(LEGACY_OWNERSHIP);
    return { ok: true, route_active: false };
}
function payload(path) {
    path = `${path ?? ''}`;
    if (!match(path, /^\/var\/run\/nftflow\/rpc-[A-Za-z0-9]+\/payload$/)) return { ok: false, error: 'invalid internal RPC input path' };
    let raw = read_text(path);
    return raw == null ? { ok: false, error: 'cannot read internal RPC input file' } : { ok: true, raw };
}

function dispatch(command, args) {
    if (command == 'routing-read') return read_current();
    if (command == 'routing-validate') return validate(args[0]);
    if (command == 'routing-save') return save(args[0]);
    if (command == 'routing-apply') return apply(args[0], true);
    if (command == 'routing-validate-file' || command == 'routing-save-file' || command == 'routing-apply-file') {
        let input = payload(args[0]);
        if (!input.ok) return { ok: false, error: input.error };
        if (command == 'routing-validate-file') return validate(input.raw);
        if (command == 'routing-save-file') return save(input.raw);
        return apply(input.raw, true);
    }
    if (command == 'route') {
        let mode = args[0] || '';
        if (mode == 'del') return remove_routes();
        if (mode == 'add' || mode == 'apply') {
            let raw = read_text(SOURCE);
            if (!raw) return { ok: false, error: `cannot read ${SOURCE}` };
            return apply(raw, false);
        }
        return { ok: false, error: 'route mode must be add, apply or del' };
    }
    if (command == 'route-apply') {
        let raw = read_text(SOURCE);
        if (!raw) return { ok: false, error: `cannot read ${SOURCE}` };
        return apply(raw, false);
    }
    if (command == 'status') {
        let raw = read_text(APPLIED) || read_text(SOURCE);
        if (!raw) return { ok: true, active: false, ipv4: false, ipv6: false };
        let parsed = parse_config(raw);
        if (!parsed.ok) return { ok: false, error: parsed.error, active: false, ipv4: false, ipv6: false };
        let state = state_status(parsed.state);
        return { ok: true, active: state.active, ipv4: state.ipv4, ipv6: state.ipv6 };
    }
    return { ok: false, error: `unsupported routing command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
