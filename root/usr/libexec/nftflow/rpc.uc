#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0
// Composite RPC operations. This process may block; rpcd invokes it asynchronously.

'use strict';

import * as fs from 'fs';

const CTL = '/usr/libexec/nftflow/nftflowctl';
const RUNTIME = '/var/run/nftflow';
const SAVED_CONFIG = '/etc/nftflow/config.yaml';
const SAVED_ROUTING = '/etc/nftflow/routing.conf';
const DEFAULT_CONFIG = '/usr/share/nftflow/defaults/config.yaml';
const DEFAULT_ROUTING = '/usr/share/nftflow/defaults/routing.conf';
const APPLIED_CONFIG = `${RUNTIME}/config.applied.yaml`;
const APPLIED_ROUTING = `${RUNTIME}/routing.applied.conf`;
const CANDIDATE_ROUTING = `${RUNTIME}/routing.candidate.conf`;

function q(value) {
    return `'${replace(`${value == null ? '' : value}`, /'/g, `'\\''`)}'`;
}

function capture(command) {
    let proc = fs.popen(`${command} 2>&1`, 'r');
    if (!proc) return { ok: false, output: '', error: 'unable to execute command' };
    let output = proc.read('all') || '';
    let rc = proc.close();
    let ok = rc === true || rc === 0;
    return { ok, output, error: ok ? null : (trim(output) || 'command failed') };
}

function read_text(path) {
    return fs.readfile(path);
}

function parse_result(output) {
    let lines = split(trim(output || ''), /\r?\n/);
    for (let i = length(lines) - 1; i >= 0; i--) {
        let line = trim(lines[i] || '');
        if (!line) continue;
        try {
            let value = json(line);
            if (type(value) == 'object') return value;
        } catch (e) {}
    }
    return { ok: false, error: trim(output || '') || 'controller returned no JSON' };
}

function run_ctl(args) {
    let command = `/bin/sh ${q(CTL)}`;
    for (let arg in args) command += ` ${q(arg)}`;
    let executed = capture(command);
    let result = parse_result(executed.output || '');
    if (!executed.ok && result.ok === true)
        return { ok: false, error: executed.error || 'controller failed' };
    return result;
}

function config_read_effective() {
    let result = run_ctl([ 'config-read' ]);
    if (result && result.ok === true) return result;

    let config = read_text(DEFAULT_CONFIG);
    if (config == null) return result;

    return {
        ok: true,
        config,
        path: SAVED_CONFIG,
        bytes: length(config),
        using_default: true,
        applied: read_text(APPLIED_CONFIG) != null,
        applied_path: APPLIED_CONFIG
    };
}

function firewall_runtime_effective() {
    let result = run_ctl([ 'firewall-read' ]);
    if (!result || result.ok !== true) return result;

    return {
        ok: true,
        active: result.active || '# No managed NftFlow nftables tables were found.\n',
        active_found: result.active_found === true,
        table_count: result.table_count || 0,
        active_table_count: result.active_table_count || 0,
        missing_tables: result.missing_tables || []
    };
}

function routing_runtime_text(table_id, ipv6) {
    let rule4 = capture('ip -4 rule show');
    let route4 = capture(`ip -4 route show table ${int(table_id)}`);
    let output = '# ip -4 rule show\n' + (rule4.ok ? trim(rule4.output) : '(unavailable)') +
        `\n\n# ip -4 route show table ${int(table_id)}\n` + (route4.ok ? trim(route4.output) : '(unavailable)');

    if (ipv6) {
        let rule6 = capture('ip -6 rule show');
        let route6 = capture(`ip -6 route show table ${int(table_id)}`);
        output += '\n\n# ip -6 rule show\n' + (rule6.ok ? trim(rule6.output) : '(unavailable)') +
            `\n\n# ip -6 route show table ${int(table_id)}\n` + (route6.ok ? trim(route6.output) : '(unavailable)');
    }

    return output + '\n';
}

function routing_read_effective() {
    let result = run_ctl([ 'routing-read' ]);
    if (result && result.ok === true) return result;

    let config = read_text(DEFAULT_ROUTING);
    if (config == null) return result;

    let checked = run_ctl([ 'routing-validate', config ]);
    if (!checked || checked.ok !== true) return result;

    let status = run_ctl([ 'status' ]);
    let table_id = checked.routing_table || 100;
    let applied = read_text(APPLIED_ROUTING);

    return {
        ok: true,
        path: SAVED_ROUTING,
        config: checked.config || config,
        bytes: length(checked.config || config),
        using_default: true,
        commands: checked.commands || [],
        route_commands: checked.route_commands || [],
        rule_commands: checked.rule_commands || [],
        active: routing_runtime_text(table_id, checked.ipv6_enabled === true),
        route_active: status && status.ok === true && status.route_active === true,
        route_ipv4: status && status.ok === true && status.route_active === true,
        route_ipv6: status && status.ok === true && status.route_ipv6 === true,
        ipv6_enabled: checked.ipv6_enabled === true,
        firewall_mark: checked.firewall_mark,
        routing_table: table_id,
        applied_config: applied || '',
        applied_path: APPLIED_ROUTING,
        candidate_path: CANDIDATE_ROUTING
    };
}

function status_with_defaults() {
    let result = run_ctl([ 'status' ]);
    if (!result || result.ok !== true) return result;

    if (read_text(SAVED_ROUTING) == null) {
        let routing = read_text(DEFAULT_ROUTING);
        if (routing != null) {
            let checked = run_ctl([ 'routing-validate', routing ]);
            if (checked && checked.ok === true) {
                result.routing_configured = true;
                result.policy_route_commands = checked.commands || [];
                result.routing_default = true;
            }
        }
    }

    return result;
}

function dispatch(command) {
    switch (command) {
    case 'status':
        return status_with_defaults();
    case 'config-read':
        return config_read_effective();
    case 'firewall-runtime':
        return firewall_runtime_effective();
    case 'routing-read':
        return routing_read_effective();
    default:
        return { ok: false, error: `unsupported RPC helper command: ${command}` };
    }
}

let result;
try {
    result = dispatch(ARGV[0] || '');
} catch (e) {
    result = { ok: false, error: `${e}` };
}

printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
