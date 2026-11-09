'use strict';

// A self-contained protobuf-wire reader for Xray/V2Ray GeoSite and GeoIP.
// Keep the DAT in a transferable ArrayBuffer and decode only requested rules.
// No external libraries, network access, or router-side search are necessary.

var dataset = null;
var generation = 0;
var utf8 = new TextDecoder('utf-8', { fatal: true });
var PAGE = 100;
var PREVIEW = 8;
var MAX_GROUPS = 80;
var MAX_BYTES = 128 * 1024 * 1024;

function bad(reason) { throw new Error(reason); }

function numberAt(bytes, position, end) {
    var value = 0, factor = 1, i = 0;
    while (i++ < 10 && position < end) {
        var byte = bytes[position++];
        value += (byte & 127) * factor;
        if (!(byte & 128)) return { value: value, next: position };
        factor *= 128;
    }
    bad('Truncated or invalid protobuf varint');
}

function fieldAt(bytes, position, end) {
    var tag = numberAt(bytes, position, end);
    var num = Math.floor(tag.value / 8), wire = tag.value % 8;
    if (!Number.isSafeInteger(tag.value) || num < 1) bad('Invalid protobuf field number');
    var current = tag.next, value = null, from = null, to = null;

    if (wire === 0) {
        var v = numberAt(bytes, current, end);
        value = v.value;
        current = v.next;
    } else if (wire === 2) {
        var size = numberAt(bytes, current, end);
        from = size.next;
        to = from + size.value;
        if (!Number.isSafeInteger(to) || size.value < 0 || to > end)
            bad('Invalid protobuf field length');
        current = to;
    } else if (wire === 1 || wire === 5) {
        current += wire === 1 ? 8 : 4;
        if (current > end) bad('Truncated fixed-width protobuf field');
    } else {
        bad('Unsupported protobuf wire type ' + wire);
    }
    return { num: num, wire: wire, value: value, from: from, to: to, next: current };
}

function stringAt(bytes, from, to) {
    return utf8.decode(bytes.subarray(from, to));
}

function readIndex(bytes, kind) {
    var categories = new Map(), groups = [], total = 0, offset = 0;
    while (offset < bytes.length) {
        var outer = fieldAt(bytes, offset, bytes.length);
        offset = outer.next;
        if (outer.num !== 1 || outer.wire !== 2) continue;

        var pos = outer.from, name = '', count = 0, inverse = false;
        while (pos < outer.to) {
            var f = fieldAt(bytes, pos, outer.to);
            pos = f.next;
            if (f.num === 1 && f.wire === 2)
                name = stringAt(bytes, f.from, f.to).toLowerCase();
            else if (f.num === 2 && f.wire === 2)
                count++;
            else if (f.num === 3 && f.wire === 0 && kind === 'geoip')
                inverse = f.value !== 0;
        }
        if (!name || name.length > 256) bad('Invalid GeoData category');
        if (groups.length >= 50000 || (total += count) > 5000000)
            bad('GeoData category index exceeds safety limits');
        groups.push({ name: name, from: outer.from, to: outer.to, count: count, inverse: inverse });

        var c = categories.get(name);
        if (!c) {
            c = { name: name, count: 0, inverse: false };
            categories.set(name, c);
        }
        c.count += count;
        c.inverse = c.inverse || inverse;
    }
    if (!groups.length) bad('No GeoData categories were found');
    return { kind: kind, bytes: bytes, groups: groups,
        categories: Array.from(categories.values()).sort(function(a, b) {
            return a.name.localeCompare(b.name);
        }), total: total };
}

function attribute(bytes, from, to) {
    var key = '', boolValue = null, numeric = null;
    while (from < to) {
        var f = fieldAt(bytes, from, to);
        from = f.next;
        if (f.num === 1 && f.wire === 2)
            key = stringAt(bytes, f.from, f.to);
        else if (f.num === 2 && f.wire === 0)
            boolValue = f.value !== 0;
        else if (f.num === 3 && f.wire === 0)
            numeric = f.value;
    }
    if (!key) return null;
    if (numeric !== null) return key + '=' + numeric;
    if (boolValue === false) return key + '=false';
    return key;
}

function domainEntry(bytes, start, end, detailed) {
    var pos = start, type = 0, value = '', attrs = [];
    while (pos < end) {
        var f = fieldAt(bytes, pos, end);
        pos = f.next;
        if (f.num === 1 && f.wire === 0)
            type = f.value;
        else if (f.num === 2 && f.wire === 2)
            value = stringAt(bytes, f.from, f.to);
        else if (f.num === 3 && f.wire === 2 && detailed) {
            var a = attribute(bytes, f.from, f.to);
            if (a !== null) attrs.push(a);
        }
    }
    return { type: [ 'keyword', 'regexp', 'domain', 'full' ][type] || 'unknown',
        value: value, attributes: attrs };
}

function ipString(addr) {
    if (addr.length === 4) return Array.from(addr).join('.');
    var groups = [];
    for (var i = 0; i < 16; i += 2)
        groups.push((addr[i] << 8) | addr[i + 1]);

    var bestStart = -1, bestLength = 1;
    for (var start = 0; start < groups.length;) {
        if (groups[start] !== 0) { start++; continue; }
        var end = start;
        while (end < groups.length && groups[end] === 0) end++;
        if (end - start > bestLength) {
            bestStart = start;
            bestLength = end - start;
        }
        start = end;
    }
    var format = function(items) {
        return items.map(function(x) { return x.toString(16); }).join(':');
    };
    if (bestStart < 0) return format(groups);
    return format(groups.slice(0, bestStart)) + '::' +
        format(groups.slice(bestStart + bestLength));
}

function ipEntry(bytes, start, end, detailed) {
    var pos = start, addr = null, prefix = 0;
    while (pos < end) {
        var f = fieldAt(bytes, pos, end);
        pos = f.next;
        if (f.num === 1 && f.wire === 2)
            addr = bytes.subarray(f.from, f.to);
        else if (f.num === 2 && f.wire === 0)
            prefix = f.value;
    }
    if (!addr || (addr.length !== 4 && addr.length !== 16) ||
        prefix < 0 || prefix > addr.length * 8)
        bad('Invalid GeoIP CIDR entry');
    return { type: 'cidr', value: detailed ? ipString(addr) + '/' + prefix : '',
        address: addr, prefix: prefix, attributes: [] };
}

function entry(bytes, kind, from, to, detailed) {
    return kind === 'geosite'
        ? domainEntry(bytes, from, to, detailed)
        : ipEntry(bytes, from, to, detailed);
}

function publicEntry(e) {
    return { type: e.type, value: e.value, attributes: e.attributes };
}

function ipv4(input) {
    var parts = input.split('.');
    if (parts.length !== 4) return null;
    var data = [];
    for (var i = 0; i < 4; i++) {
        if (!/^[0-9]{1,3}$/.test(parts[i]) || Number(parts[i]) > 255) return null;
        data.push(Number(parts[i]));
    }
    return data;
}

function ipAddress(input) {
    var v4 = ipv4(input);
    if (v4) return Uint8Array.from(v4);
    if (input.indexOf(':') < 0 || input.indexOf('%') >= 0) return null;

    var encoded = input.toLowerCase();
    var tail = encoded.lastIndexOf(':') + 1;
    if (encoded.indexOf('.') >= 0) {
        var embedded = ipv4(encoded.slice(tail));
        if (!embedded) return null;
        encoded = encoded.slice(0, tail) +
            (((embedded[0] << 8) | embedded[1]).toString(16)) + ':' +
            (((embedded[2] << 8) | embedded[3]).toString(16));
    }
    if (!/^[0-9a-f:]+$/.test(encoded) || encoded.includes(':::')) return null;
    var parts = encoded.split('::');
    if (parts.length > 2) return null;
    function words(fragment) {
        if (!fragment) return [];
        var split = fragment.split(':');
        if (split.some(function(x) { return !x || x.length > 4 || !/^[0-9a-f]+$/.test(x); }))
            return null;
        return split.map(function(x) { return parseInt(x, 16); });
    }
    var a = words(parts[0]), b = words(parts.length > 1 ? parts[1] : '');
    if (!a || !b) return null;
    var missing = 8 - a.length - b.length;
    if (parts.length === 1 && missing !== 0) return null;
    if (parts.length === 2 && missing < 1) return null;
    var values = a.concat(Array(missing).fill(0), b);
    if (values.length !== 8) return null;
    var out = new Uint8Array(16);
    values.forEach(function(x, i) { out[i * 2] = x >>> 8; out[i * 2 + 1] = x & 255; });
    return out;
}

function containsCidr(e, address) {
    if (e.address.length !== address.length) return false;
    var bytes = Math.floor(e.prefix / 8), rest = e.prefix % 8;
    for (var i = 0; i < bytes; i++)
        if (e.address[i] !== address[i]) return false;
    if (rest) {
        var mask = (255 << (8 - rest)) & 255;
        if ((e.address[bytes] & mask) !== (address[bytes] & mask)) return false;
    }
    return true;
}

function domainMatch(e, hostname) {
    var rule = e.value.toLowerCase();
    if (!rule) return false;
    if (e.type === 'full') return hostname === rule;
    if (e.type === 'keyword') return hostname.includes(rule);
    if (e.type === 'domain') return hostname === rule || hostname.endsWith('.' + rule);
    return false;
}

function matchText(e, value, regexp, sensitive) {
    return regexp ? regexp.test(e.value)
        : (sensitive ? e.value.includes(value) : e.value.toLowerCase().includes(value.toLowerCase()));
}

function yieldToMessages() {
    return new Promise(function(resolve) { setTimeout(resolve, 0); });
}

async function browse(request, token) {
    var category = request.category.toLowerCase();
    var page = Number(request.page) || 0;
    if (!Number.isSafeInteger(page) || page < 0 || page > 100000) bad('Invalid page number');

    var filter = String(request.filter || '').slice(0, 256).toLowerCase();
    var type = String(request.type || 'all');
    var filtered = !!filter || type !== 'all';
    var matched = 0, processed = 0, rows = [], sources = dataset.groups;
    var found = dataset.categories.find(function(c) { return c.name === category; });
    if (!found) bad('GeoData category not found: ' + category);

    for (var gi = 0; gi < sources.length; gi++) {
        var group = sources[gi];
        if (group.name !== category) continue;
        var position = group.from;
        while (position < group.to) {
            var f = fieldAt(dataset.bytes, position, group.to);
            position = f.next;
            if (f.num !== 2 || f.wire !== 2) continue;
            if (!filtered && matched >= (page + 1) * PAGE) break;
            var rule = entry(dataset.bytes, dataset.kind, f.from, f.to, filtered);
            if (type !== 'all' && rule.type !== type) continue;
            if (filter && !rule.value.toLowerCase().includes(filter)) continue;
            if (matched >= page * PAGE && rows.length < PAGE)
                rows.push(publicEntry(filtered ? rule :
                    entry(dataset.bytes, dataset.kind, f.from, f.to, true)));
            matched++;
            if (++processed % 3000 === 0) {
                await yieldToMessages();
                if (token !== generation) return;
            }
        }
        if (!filtered && rows.length >= PAGE) break;
    }
    if (token === generation)
        postMessage({ type: 'browse', id: request.id,
            result: { category: category, page: page, total: filtered ? matched : found.count,
                entries: rows, inverse: found.inverse } });
}

async function search(request, token) {
    var query = String(request.query || '').trim();
    if (!query || query.length > 256) bad('Query must have 1 to 256 characters');
    var mode = request.mode === 'text' ? 'text' : 'match';
    var sensitive = !!request.sensitive, expression = null, hostname = query.toLowerCase();
    var address = null, invalidRegex = 0;
    if (mode === 'text' && request.regex) {
        if (query.length > 128) bad('Regex is too long');
        expression = new RegExp(query, sensitive ? '' : 'i');
    } else if (mode === 'match' && dataset.kind === 'geoip') {
        address = ipAddress(query);
        if (!address) bad('Enter a valid IPv4 or IPv6 address');
    } else if (mode === 'match' && !/^[A-Za-z0-9_.-]{1,253}$/.test(query)) {
        bad('Enter a valid domain');
    }

    var matches = new Map(), inverse = new Map(), total = 0, processed = 0;
    var lastReport = 0, rawTotal = dataset.total, ruleIndex = 0;
    var groups = dataset.groups;

    for (var gi = 0; gi < groups.length; gi++) {
        var group = groups[gi], pos = group.from, isInverse = dataset.kind === 'geoip' &&
            mode === 'match' && group.inverse;
        if (isInverse && !inverse.has(group.name))
            inverse.set(group.name, { within: false });

        while (pos < group.to) {
            var f = fieldAt(dataset.bytes, pos, group.to);
            pos = f.next;
            if (f.num !== 2 || f.wire !== 2) continue;
            var e = entry(dataset.bytes, dataset.kind, f.from, f.to, mode === 'text');
            var found = false;

            if (mode === 'text')
                found = matchText(e, query, expression, sensitive);
            else if (dataset.kind === 'geoip')
                found = containsCidr(e, address);
            else if (e.type === 'regexp')
                invalidRegex++;
            else
                found = domainMatch(e, hostname);

            if (isInverse) {
                if (found) inverse.get(group.name).within = true;
            } else if (found) {
                total++;
                var result = matches.get(group.name);
                if (!result) {
                    result = { name: group.name, total: 0, inverse: false, matches: [] };
                    matches.set(group.name, result);
                }
                result.total++;
                if (result.matches.length < PREVIEW)
                    result.matches.push(publicEntry(mode === 'text' ? e :
                        entry(dataset.bytes, dataset.kind, f.from, f.to, true)));
            }

            ruleIndex++;
            if (++processed % 2500 === 0) {
                if (processed - lastReport >= 15000) {
                    postMessage({ type: 'progress', id: request.id, scanned: ruleIndex,
                        total: rawTotal, matches: total, categories: matches.size });
                    lastReport = processed;
                }
                await yieldToMessages();
                if (token !== generation) return;
            }
        }
    }

    inverse.forEach(function(value, name) {
        if (value.within) return;
        total++;
        var result = matches.get(name);
        if (!result) {
            result = { name: name, total: 0, inverse: true, matches: [] };
            matches.set(name, result);
        }
        result.total++;
        result.inverse = true;
        if (result.matches.length < PREVIEW)
            result.matches.push({ type: 'inverse',
                value: 'Address outside the category CIDRs', attributes: [] });
    });

    if (token !== generation) return;
    var list = Array.from(matches.values()).sort(function(a, b) {
        return a.name.localeCompare(b.name);
    });
    postMessage({ type: 'search', id: request.id, result: {
        kind: dataset.kind, scanned: ruleIndex, indexed: dataset.total,
        total: total, category_total: list.length, truncated: list.length > MAX_GROUPS,
        skipped_regex: invalidRegex, categories: list.slice(0, MAX_GROUPS)
    } });
}

self.onmessage = async function(event) {
    var req = event.data || {};
    if (req.action === 'cancel') {
        generation++;
        return;
    }
    var token = ++generation;
    try {
        if (req.action === 'load') {
            if (!['geosite', 'geoip'].includes(req.kind) ||
                !(req.buffer instanceof ArrayBuffer) ||
                !req.buffer.byteLength || req.buffer.byteLength > MAX_BYTES)
                bad('Invalid GeoData file');
            var loaded = readIndex(new Uint8Array(req.buffer), req.kind);
            if (token !== generation) return;
            dataset = loaded;
            postMessage({ type: 'ready', id: req.id, result: {
                categories: loaded.categories, total: loaded.total
            } });
        } else {
            if (!dataset) bad('GeoData has not been loaded');
            if (req.kind !== dataset.kind)
                bad('GeoData dataset mismatch; reload the selected file');
            if (req.action === 'browse') await browse(req, token);
            else if (req.action === 'search') await search(req, token);
            else bad('Unsupported GeoData operation');
        }
    } catch (error) {
        if (token === generation)
            postMessage({ type: 'error', id: req.id, error: String(error && error.message || error) });
    }
};
