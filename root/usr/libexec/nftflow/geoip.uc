// SPDX-License-Identifier: Apache-2.0

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const CACHE = '/var/lib/nftflow/geoip';

function q(value) { return `'${replace(`${value}`, /'/g, `'\\''`)}'`; }
function read_manifest() {
    try { return json(fs.readfile(`${CACHE}/current/manifest.json`) || ''); }
    catch (e) { return null; }
}

// The caller masks nft comments and strings before scanning template tokens.
export function references(text) {
    let refs = [], tags = {}, pos = 0;
    while (pos < length(text)) {
        let tail = substr(text, pos);
        let token = match(tail, /%geoip:([A-Za-z0-9_-]+)%/);
        if (!token) break;
        let start = pos + index(tail, token[0]);
        let line = start;
        while (line > 0) {
            let c = substr(text, line - 1, 1);
            if (c == ';' || c == '{' || c == '}') break;
            if (c == '\n' && (line < 2 || substr(text, line - 2, 1) != '\\')) break;
            line--;
        }
        let prefix = substr(text, line, start - line), family = 4;
        // Select the nearest ip/ip6 expression; nft checks its eventual type.
        while (true) {
            let expression = match(prefix, /(^|\s)(ip6?)(\s|$)/);
            if (!expression) break;
            family = expression[2] == 'ip6' ? 6 : 4;
            prefix = substr(prefix, index(prefix, expression[0]) + length(expression[0]) - length(expression[3]));
        }
        let tag = lc(token[1]);
        tags[tag] = true;
        push(refs, { start, end: start + length(token[0]), tag, family });
        pos = start + length(token[0]);
    }
    return { refs, tags: sort(keys(tags)) };
}

export function set_name(tag, family) { return `nftflow_geoip_${tag}${family}`; }

function varint(reader) {
    let value = 0, factor = 1;
    for (let i = 0; i < 10; i++) {
        let byte = reader.read(1);
        if (byte == null || length(byte) != 1) die('truncated GeoIP protobuf');
        let n = ord(byte);
        value += (n & 127) * factor;
        if (!(n & 128)) return value;
        factor *= 128;
    }
    die('invalid GeoIP protobuf varint');
}

function string_reader(raw) {
    return {
        raw, pos: 0,
        read: function(count) {
            let chunk = substr(this.raw, this.pos, count);
            this.pos += length(chunk);
            return chunk;
        }
    };
}

function field(reader, end) {
    let key = varint(reader), wire = key % 8, number = int(key / 8), value;
    if (number < 1) die('invalid GeoIP protobuf field');
    if (wire == 0) value = varint(reader);
    else {
        let size = wire == 2 ? varint(reader) : wire == 1 ? 8 : wire == 5 ? 4 : -1;
        let pos = reader.pos ?? reader.tell();
        if (size < 0 || size > end - pos) die('invalid GeoIP protobuf field length');
        value = reader.read(size);
        if (value == null || length(value) != size) die('truncated GeoIP protobuf field');
    }
    return { number, wire, value };
}

function cidr(raw) {
    let reader = string_reader(raw), address = null, prefix = 0;
    while (reader.pos < length(raw)) {
        let item = field(reader, length(raw));
        if (item.number == 1 && item.wire == 2) address = item.value;
        else if (item.number == 2 && item.wire == 0) prefix = item.value;
    }
    let size = length(address ?? '');
    if ((size != 4 && size != 16) || prefix > size * 8) die('invalid GeoIP CIDR');
    let parts = [];
    if (size == 4) {
        for (let i = 0; i < 4; i++) push(parts, `${ord(substr(address, i, 1))}`);
    } else {
        for (let i = 0; i < 16; i += 2)
            push(parts, sprintf('%x', ord(substr(address, i, 1)) * 256 + ord(substr(address, i + 1, 1))));
    }
    return { family: size == 4 ? 4 : 6, value: `${join(size == 4 ? '.' : ':', parts)}/${prefix}` };
}

function extract(source, size, tags) {
    let wanted = {}, networks = {};
    for (let tag in tags) wanted[tag] = true;
    let file = fs.open(source, 'r');
    if (!file) die(`cannot read GeoIP file ${source}`);
    try {
        // Read one country message at a time rather than retaining the whole DAT.
        while (file.tell() < size) {
            let entry = field(file, size);
            if (entry.number != 1 || entry.wire != 2) continue;
            let reader = string_reader(entry.value), tag = null, inverse = false;
            while (reader.pos < length(entry.value)) {
                let item = field(reader, length(entry.value));
                if (item.number == 1 && item.wire == 2) tag = lc(item.value);
                else if (item.number == 3 && item.wire == 0) inverse = item.value != 0;
            }
            if (!wanted[tag]) continue;
            if (inverse) die(`inverse GeoIP tag ${tag} cannot be used as an address set`);
            let lists = networks[tag] ?? { '4': [], '6': [] };
            reader.pos = 0;
            while (reader.pos < length(entry.value)) {
                let item = field(reader, length(entry.value));
                if (item.number != 2 || item.wire != 2) continue;
                let address = cidr(item.value);
                push(lists[`${address.family}`], address.value);
            }
            networks[tag] = lists;
        }
    } catch (e) { file.close(); die(`${e}`); }
    file.close();
    for (let tag in tags)
        if (networks[tag] == null) die(`GeoIP tag ${tag} was not found in ${source}`);
    return networks;
}

function hash_file(source) {
    let proc = fs.popen(`sha256sum ${q(source)} 2>/dev/null`, 'r');
    if (!proc) die('cannot execute sha256sum');
    let output = proc.read('all') || '', rc = proc.close();
    let hash = match(output, /^([0-9a-f]{64})\s/);
    if (rc !== 0 || !hash) die(`cannot hash GeoIP file ${source}`);
    return hash[1];
}

function render_sets(tag, lists) {
    let blocks = [];
    for (let family in [ 4, 6 ]) {
        let entries = lists[`${family}`];
        let block = `set ${set_name(tag, family)} {\n    type ipv${family}_addr\n    flags interval\n    auto-merge\n`;
        if (length(entries)) block += `    elements = {\n        ${join(',\n        ', entries)}\n    }\n`;
        push(blocks, block + '}\n');
    }
    return join('\n', blocks);
}

function discard(directory) {
    for (let name in (fs.lsdir(directory) || [])) fs.unlink(`${directory}/${name}`);
    fs.rmdir(directory);
}

function publish(manifest, sets) {
    if (system(`mkdir -p ${q(CACHE)}`) !== 0) die(`cannot create ${CACHE}`);
    let directory = fs.mkdtemp(`${CACHE}/generation-XXXXXX`);
    if (!directory) die('cannot create GeoIP cache generation');
    let pending = `${directory}.link`;
    try {
        for (let tag in manifest.tags) {
            let content = sets[tag];
            if (fs.writefile(`${directory}/${tag}.nft`, content) != length(content)) die(`cannot cache GeoIP tag ${tag}`);
        }
        let content = sprintf('%J\n', manifest);
        if (fs.writefile(`${directory}/manifest.json`, content) != length(content)) die('cannot write GeoIP manifest');
        if (fs.symlink(fs.basename(directory), pending) !== true || fs.rename(pending, `${CACHE}/current`) !== true)
            die('cannot publish GeoIP cache');
    } catch (e) {
        fs.unlink(pending);
        discard(directory);
        die(`${e}`);
    }
    // Callers hold the firewall lock, so no reader can still use an older generation.
    for (let name in (fs.lsdir(CACHE) || []))
        if (match(name, /^generation-[A-Za-z0-9]+$/) && name != fs.basename(directory)) discard(`${CACHE}/${name}`);
}

function source_info() {
    let uci = cursor();
    let source = uci.get('nftflow', 'main', 'geoip_file') || '/usr/share/xray/geoip.dat';
    if (substr(source, 0, 1) != '/') die('geoip_file must be an absolute path');
    let stat = fs.stat(source);
    if (!stat || stat.type != 'file') die(`cannot read GeoIP file ${source}`);
    return { source, stat };
}

function same_source_stat(manifest, info) {
    return manifest && manifest.source == info.source && manifest.size == info.stat.size && manifest.mtime == info.stat.mtime;
}

export function source_unchanged(manifest) { return same_source_stat(manifest, source_info()); }

export function prepare(tags) {
    if (!length(tags)) return { sets: {}, manifest: null };
    let info = source_info(), source = info.source, stat = info.stat;
    let previous = read_manifest();
    let same_tags = previous && join('\n', previous.tags || []) == join('\n', tags);
    let same_stat = same_source_stat(previous, info);
    let hash = same_stat ? previous.sha256 : hash_file(source);
    let sets = {}, reusable = previous && previous.source == source && previous.sha256 == hash && same_tags;
    if (reusable) {
        for (let tag in tags) {
            sets[tag] = fs.readfile(`${CACHE}/current/${tag}.nft`);
            if (sets[tag] == null) { reusable = false; break; }
        }
    }
    if (!reusable) {
        let networks = extract(source, stat.size, tags);
        for (let tag in tags) sets[tag] = render_sets(tag, networks[tag]);
        // Do not publish a cache built while an external updater replaced the DAT.
        let after = fs.stat(source);
        if (!after || after.size != stat.size || after.mtime != stat.mtime || hash_file(source) != hash)
            die('GeoIP file changed while generating sets; retry the operation');
    }
    let manifest = { source, size: stat.size, mtime: stat.mtime, sha256: hash, tags };
    if (!reusable) publish(manifest, sets);
    else if (!same_stat) {
        let content = sprintf('%J\n', manifest), pending = `${CACHE}/current/manifest.pending.json`;
        if (fs.writefile(pending, content) != length(content) || fs.rename(pending, `${CACHE}/current/manifest.json`) !== true) {
            fs.unlink(pending);
            die('cannot update GeoIP manifest');
        }
    }
    return { sets, manifest };
}

export function hot_transaction(sets, tables) {
    let commands = [], seen = {};
    for (let table in tables) {
        for (let tag in table.tags) {
            for (let family in [ 4, 6 ]) {
                let name = set_name(tag, family), key = `${table.family} ${name}`;
                if (seen[key]) continue;
                seen[key] = true;
                // Read only our generated format, not user nftables syntax.
                let block = split(sets[tag], `set ${name} {\n`)[1];
                if (block == null) die(`missing cached GeoIP set ${name}`);
                block = split(block, '\n}\n')[0];
                let entries = match(block, /elements = \{([^}]*)\}/);
                push(commands, `flush set ${table.family} nftflow ${name}`);
                if (entries && trim(entries[1]))
                    push(commands, `add element ${table.family} nftflow ${name} {${entries[1]}}`);
            }
        }
    }
    return join('\n', commands) + '\n';
}
