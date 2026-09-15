#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0

'use strict';

import * as fs from 'fs';

let ubus = require('ubus').connect();

function q(value) { return `'${replace(`${value ?? ''}`, /'/g, `'\\''`)}'`; }
function capture(command) {
    let proc = fs.popen(`${command} 2>&1`, 'r');
    if (!proc) return { ok: false, output: 'unable to execute command' };
    let output = proc.read('all') || '';
    let rc = proc.close();
    return { ok: rc === 0, output: trim(output || '') };
}
function valid_domain(value) {
    value = trim(`${value ?? ''}`);
    if (!value || length(value) > 253 || !match(value, /^[A-Za-z0-9_.-]+$/)) return false;
    if (substr(value, 0, 1) == '.' || substr(value, -1) == '.') return false;
    return true;
}
function valid_ipv4(value) {
    if (!match(value, /^[0-9]+(?:\.[0-9]+){3}$/)) return false;
    let parts = split(value, '.');
    if (length(parts) != 4) return false;
    for (let part in parts) {
        if (length(part) > 3 || int(part) < 0 || int(part) > 255) return false;
    }
    return true;
}
function valid_ipv6(value) {
    return index(value, ':') >= 0 && match(value, /^[0-9A-Fa-f:.]+$/) != null;
}
function address_family(value) {
    if (valid_ipv4(value)) return 4;
    if (valid_ipv6(value)) return 6;
    return null;
}
function normalize_address(value) {
    value = trim(`${value ?? ''}`);
    let bracketed = match(value, /^\[([0-9A-Fa-f:.]+)\](?::[0-9]+)?$/);
    if (bracketed) value = bracketed[1];
    let hash = index(value, '#');
    if (hash >= 0) value = substr(value, 0, hash);
    let ipv4_port = match(value, /^([0-9]+(?:\.[0-9]+){3}):[0-9]+$/);
    if (ipv4_port) value = ipv4_port[1];
    return address_family(value) ? value : null;
}
function add_address(addresses, seen, value) {
    let address = normalize_address(value);
    if (!address || seen[address]) return;
    seen[address] = true;
    push(addresses, { address, family: address_family(address) });
}
function parse_nslookup(output) {
    let addresses = [], seen = {}, answer = false;
    for (let source_line in split(output || '', '\n')) {
        let line = trim(source_line);
        if (match(line, /^Name(?:\s+[0-9]+)?:/)) answer = true;
        let found = match(line, /^Address(?:\s+[0-9]+)?:\s+(\S+)/);
        if (found && answer) add_address(addresses, seen, found[1]);
    }
    return addresses;
}
function lan_target() {
    if (!ubus) return { ok: false, error: 'unable to connect to ubus' };
    let status;
    try { status = ubus.call('network.interface.lan', 'status', {}); }
    catch (e) { return { ok: false, error: `unable to read LAN interface: ${e}` }; }
    if (type(status) != 'object') return { ok: false, error: 'LAN interface status is unavailable' };

    let device = `${status.l3_device || status.device || ''}`;
    let address = null;
    let ipv4 = status['ipv4-address'];
    if (type(ipv4) == 'array') {
        for (let entry in ipv4) {
            if (type(entry) == 'object' && valid_ipv4(`${entry.address || ''}`)) {
                address = `${entry.address}`;
                break;
            }
        }
    }
    if (!device || !address) return { ok: false, error: 'LAN bridge or IPv4 address is unavailable' };
    return { ok: true, device, address };
}
function dns_plain(domain, source) {
    let lan = lan_target();
    if (!lan.ok) return lan;

    let result;
    if (source == 'router') {
        result = capture(`/bin/busybox nslookup ${q(domain)} ${q(lan.address)}`);
    } else {
        let script = `set -e\n` +
            `DEV=${q(lan.device)}\n` +
            `ROUTER=${q(lan.address)}\n` +
            `DOMAIN=${q(domain)}\n` +
            `NS="nftflow-diag-$$"\n` +
            `HOST="nfd$$"\n` +
            `SRC="169.254.254.$((($$ % 200) + 20))"\n` +
            `cleanup() {\n` +
            `  ip route del "$SRC/32" dev "$DEV" >/dev/null 2>&1 || true\n` +
            `  ip netns del "$NS" >/dev/null 2>&1 || true\n` +
            `  ip link del "$HOST" >/dev/null 2>&1 || true\n` +
            `}\n` +
            `trap cleanup EXIT INT TERM\n` +
            `[ -d "/sys/class/net/$DEV/bridge" ] || { echo "LAN device $DEV is not a bridge" >&2; exit 1; }\n` +
            `ip netns add "$NS"\n` +
            `ip link add "$HOST" type veth peer name eth0 netns "$NS"\n` +
            `ip link set "$HOST" master "$DEV"\n` +
            `ip link set "$HOST" up\n` +
            `ip netns exec "$NS" ip link set lo up\n` +
            `ip netns exec "$NS" ip link set eth0 up\n` +
            `ip netns exec "$NS" ip addr add "$SRC/32" dev eth0\n` +
            `ip netns exec "$NS" ip route add "$ROUTER/32" dev eth0\n` +
            `ip route add "$SRC/32" dev "$DEV"\n` +
            `ip netns exec "$NS" /bin/busybox nslookup "$DOMAIN" "$ROUTER"\n`;
        result = capture(`/bin/sh -c ${q(script)}`);
    }

    let addresses = parse_nslookup(result.output);
    return {
        ok: result.ok && length(addresses) > 0,
        source,
        resolver: lan.address,
        addresses,
        detail: result.ok && length(addresses) > 0 ? null : (result.output || 'DNS query returned no addresses')
    };
}
function doh_query(domain, record_type, answer_type) {
    let url = `https://1.1.1.1/dns-query?name=${domain}&type=${record_type}`;
    let result = capture(`/bin/uclient-fetch -q -T 5 -O - --header=${q('accept: application/dns-json')} ${q(url)}`);
    if (!result.ok) return { ok: false, addresses: [], error: result.output || `DoH ${record_type} request failed` };

    let payload;
    try { payload = json(result.output || ''); }
    catch (e) { return { ok: false, addresses: [], error: `invalid DoH ${record_type} response` }; }
    if (type(payload) != 'object') return { ok: false, addresses: [], error: `invalid DoH ${record_type} response` };
    if (int(payload.Status || 0) !== 0) return { ok: false, addresses: [], error: `DoH ${record_type} status ${payload.Status}` };

    let addresses = [], seen = {}, answers = payload.Answer;
    if (type(answers) == 'array') {
        for (let answer in answers) {
            if (type(answer) != 'object' || int(answer.type || 0) !== answer_type) continue;
            add_address(addresses, seen, answer.data);
        }
    }
    return { ok: true, addresses };
}
function dns_doh(domain) {
    let a = doh_query(domain, 'A', 1);
    let aaaa = doh_query(domain, 'AAAA', 28);
    let addresses = [], seen = {};
    for (let item in a.addresses || []) add_address(addresses, seen, item.address);
    for (let item in aaaa.addresses || []) add_address(addresses, seen, item.address);
    let errors = [];
    if (!a.ok) push(errors, a.error);
    if (!aaaa.ok) push(errors, aaaa.error);
    return {
        ok: a.ok && aaaa.ok,
        source: 'doh',
        resolver: '1.1.1.1',
        addresses,
        detail: length(errors) ? join('; ', errors) : null
    };
}
function diagnostic_dns(source, domain) {
    domain = trim(`${domain ?? ''}`);
    if (!valid_domain(domain)) return { ok: false, error: 'invalid domain name' };
    if (source == 'lan' || source == 'router') return dns_plain(domain, source);
    if (source == 'doh') return dns_doh(domain);
    return { ok: false, error: 'DNS source must be lan, router or doh' };
}
function diagnostic_request(domain) {
    domain = trim(`${domain ?? ''}`);
    if (!valid_domain(domain)) return { ok: false, error: 'invalid domain name' };
    let url = `https://${domain}/`;
    let result = capture(`/bin/uclient-fetch -q -T 8 -O /dev/null ${q(url)}`);
    return {
        ok: result.ok,
        url,
        detail: result.ok ? null : (result.output || 'page request failed')
    };
}
function runtime_sets(family) {
    let result = capture('/usr/sbin/nft -j list sets');
    if (!result.ok) return { ok: false, error: result.output || 'unable to list nftables sets' };

    let payload;
    try { payload = json(result.output || ''); }
    catch (e) { return { ok: false, error: 'invalid nftables JSON output' }; }

    let sets = [], wanted = family == 4 ? 'ipv4_addr' : 'ipv6_addr';
    let objects = type(payload) == 'object' ? payload.nftables : null;
    if (type(objects) != 'array') return { ok: false, error: 'invalid nftables set list' };

    for (let object in objects) {
        if (type(object) != 'object' || type(object.set) != 'object') continue;
        let set = object.set;
        let set_type = set.type;
        let matches_type = false;
        if (type(set_type) == 'string') matches_type = set_type == wanted;
        else if (type(set_type) == 'array') {
            for (let item in set_type) if (`${item}` == wanted) matches_type = true;
        }
        if (!matches_type || !set.family || !set.table || !set.name) continue;
        push(sets, { family: `${set.family}`, table: `${set.table}`, set: `${set.name}` });
    }
    return { ok: true, sets };
}
function diagnostic_firewall(address) {
    address = trim(`${address ?? ''}`);
    let family = address_family(address);
    if (!family) return { ok: false, error: 'invalid IP address' };

    let discovered = runtime_sets(family);
    if (!discovered.ok) return { ok: false, address, family, error: discovered.error };

    let matches = [];
    for (let spec in discovered.sets) {
        let result = capture(`/usr/sbin/nft get element ${q(spec.family)} ${q(spec.table)} ${q(spec.set)} ${q(`{ ${address} }`)}`);
        if (!result.ok) continue;
        let expires = null;
        let found = match(result.output || '', /expires\s+([^\s,}]+)/);
        if (found) expires = found[1];
        push(matches, {
            family: spec.family,
            table: spec.table,
            set: spec.set,
            expires,
            detail: result.output || null
        });
    }
    return {
        ok: true,
        address,
        family,
        matches
    };
}
function dispatch(command, args) {
    if (command == 'diagnostic-dns') return diagnostic_dns(args[0] || '', args[1] || '');
    if (command == 'diagnostic-request') return diagnostic_request(args[0] || '');
    if (command == 'diagnostic-firewall') return diagnostic_firewall(args[0] || '');
    return { ok: false, error: `unsupported diagnostics command: ${command}` };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: `${e}` }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
