#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0
// Read-only, on-demand explorer for Xray/V2Ray GeoSite and GeoIP DAT files.

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const MAX_FILE_SIZE = 128 * 1024 * 1024;
const MAX_ENTRY_SIZE = 32 * 1024 * 1024;
const PAGE_SIZE = 100;
const PREVIEW_SIZE = 8;
const MAX_RESULT_GROUPS = 100;
const SEARCH_BATCH_ENTRIES = 5000;
const INDEX_DIRECTORY = '/tmp/nftflow-geodata';

function source_info(kind) {
    if (kind != 'geosite' && kind != 'geoip') die('unsupported GeoData type');
    let option = kind == 'geosite' ? 'geosite_file' : 'geoip_file';
    let path = cursor().get('nftflow', 'main', option);
    if (!path) die(option + ' is not configured in Settings');
    if (substr(path, 0, 1) != '/') die(option + ' must be an absolute path');
    let stat = fs.stat(path);
    if (!stat || stat.type != 'file') die('cannot read ' + kind + ' file: ' + path);
    if (stat.size > MAX_FILE_SIZE) die(kind + ' file exceeds the 128 MiB query limit');
    return { kind, path, size: stat.size, mtime: stat.mtime };
}

function varint(reader) {
    let value = 0, factor = 1;
    for (let i = 0; i < 10; i++) {
        let chunk = reader.read(1);
        if (chunk == null || length(chunk) != 1) die('truncated GeoData protobuf');
        let byte = ord(chunk);
        value += (byte & 127) * factor;
        if (!(byte & 128)) return value;
        factor *= 128;
    }
    die('invalid GeoData protobuf varint');
}

function string_reader(raw) {
    return {
        raw, pos: 0,
        read: function(count) {
            let result = substr(this.raw, this.pos, count);
            this.pos += length(result);
            return result;
        }
    };
}

function field(reader, end, skip_entry) {
    let key = varint(reader), wire = key % 8, number = int(key / 8), value;
    if (number < 1) die('invalid GeoData protobuf field');
    if (wire == 0) value = varint(reader);
    else {
        let count = wire == 2 ? varint(reader) : wire == 1 ? 8 : wire == 5 ? 4 : -1;
        let position = reader.pos ?? reader.tell();
        if (count < 0 || count > end - position || count > MAX_ENTRY_SIZE)
            die('invalid or oversized GeoData protobuf field');
        if (skip_entry && reader.raw != null && number == 2) {
            reader.pos += count;
            value = null;
        } else {
            value = reader.read(count);
            if (value == null || length(value) != count)
                die('truncated GeoData protobuf field');
        }
    }
    return { number, wire, value };
}

function scan(source, visit) {
    let file = fs.open(source.path, 'r');
    if (!file) die('cannot open GeoData file: ' + source.path);
    try {
        while (file.tell() < source.size) {
            let item = field(file, source.size);
            if (item.number == 1 && item.wire == 2) visit(item.value);
        }
    } catch (e) {
        file.close();
        die('failed to read ' + source.kind + ': ' + e);
    }
    file.close();
}

function metadata(raw) {
    let reader = string_reader(raw), tag = null, count = 0, inverse = false;
    while (reader.pos < length(raw)) {
        let item = field(reader, length(raw), true);
        if (item.number == 1 && item.wire == 2) tag = lc(item.value);
        else if (item.number == 2 && item.wire == 2) count++;
        else if (item.number == 3 && item.wire == 0) inverse = item.value != 0;
    }
    if (!tag) die('GeoData entry has no category name');
    return { tag, count, inverse };
}


function load_index(source) {
    let path = INDEX_DIRECTORY + '/' + source.kind + '.json';
    let cached;
    try { cached = json(fs.readfile(path, 2 * 1024 * 1024) || ''); }
    catch (e) {}
    if (cached && cached.version == 1 && cached.path == source.path &&
        cached.size == source.size && cached.mtime == source.mtime &&
        type(cached.categories) == 'array' && type(cached.groups) == 'array')
        return cached;

    let groups = [], category_map = {}, file = fs.open(source.path, 'r');
    if (!file) die('cannot open GeoData file: ' + source.path);
    try {
        while (file.tell() < source.size) {
            let offset = file.tell(), item = field(file, source.size);
            if (item.number != 1 || item.wire != 2) continue;
            let meta = metadata(item.value);
            push(groups, { name: meta.tag, offset, count: meta.count, inverse: meta.inverse });
            let category = category_map[meta.tag];
            if (!category) {
                category = { name: meta.tag, count: 0, inverse: false };
                category_map[meta.tag] = category;
            }
            category.count += meta.count;
            category.inverse = category.inverse || meta.inverse;
        }
    } catch (e) {
        file.close();
        die('failed to index ' + source.kind + ': ' + e);
    }
    file.close();
    let after = fs.stat(source.path);
    if (!after || after.size != source.size || after.mtime != source.mtime)
        die('GeoData source changed during indexing; retry');

    let categories = [];
    for (let tag in sort(keys(category_map))) push(categories, category_map[tag]);
    let built = {
        version: 1, path: source.path, size: source.size, mtime: source.mtime,
        groups, categories
    };
    if (fs.stat(INDEX_DIRECTORY) == null && fs.mkdir(INDEX_DIRECTORY, 0o700) !== true)
        return built; // Read-only mode still works without a writable cache.
    let temp = fs.mkdtemp(INDEX_DIRECTORY + '/build-XXXXXX');
    if (temp) {
        let payload = sprintf('%J\n', built), staged = temp + '/index.json';
        if (fs.writefile(staged, payload) == length(payload)) fs.rename(staged, path);
        fs.unlink(staged);
        fs.rmdir(temp);
    }
    return built;
}

function read_group(file, group, size) {
    if (file.seek(group.offset) !== true) die('unable to seek GeoData category');
    let item = field(file, size);
    if (item.number != 1 || item.wire != 2)
        die('invalid GeoData category offset');
    return item.value;
}

function visit_entries(raw, visitor) {
    let reader = string_reader(raw);
    while (reader.pos < length(raw)) {
        let item = field(reader, length(raw));
        if (item.number == 2 && item.wire == 2) visitor(item.value);
    }
}

function domain_attribute(raw) {
    let reader = string_reader(raw), key = '', bool_value = null, int_value = null;
    while (reader.pos < length(raw)) {
        let item = field(reader, length(raw));
        if (item.number == 1 && item.wire == 2) key = item.value;
        else if (item.number == 2 && item.wire == 0) bool_value = item.value != 0;
        else if (item.number == 3 && item.wire == 0) int_value = item.value;
    }
    if (!key) return null;
    if (int_value != null) return key + '=' + int_value;
    if (bool_value === false) return key + '=false';
    return key;
}

function domain_entry(raw, with_attrs) {
    let reader = string_reader(raw), kind = 2, value = '', attributes = [];
    while (reader.pos < length(raw)) {
        let item = field(reader, length(raw));
        if (item.number == 1 && item.wire == 0) kind = item.value;
        else if (item.number == 2 && item.wire == 2) value = item.value;
        else if (item.number == 3 && item.wire == 2 && with_attrs !== false) {
            let attr = domain_attribute(item.value);
            if (attr != null) push(attributes, attr);
        }
    }
    let names = [ 'keyword', 'regexp', 'domain', 'full' ];
    return { type: names[kind] ?? 'unknown', value, attributes };
}

function network_entry(raw, with_value) {
    let reader = string_reader(raw), addr = null, bits = 0;
    while (reader.pos < length(raw)) {
        let item = field(reader, length(raw));
        if (item.number == 1 && item.wire == 2) addr = item.value;
        else if (item.number == 2 && item.wire == 0) bits = item.value;
    }
    let size = length(addr ?? '');
    if ((size != 4 && size != 16) || bits > size * 8)
        die('invalid GeoIP CIDR');
    let bytes = [];
    for (let i = 0; i < size; i++) push(bytes, ord(addr, i));
    return { type: 'cidr', value: with_value === false ? '' : arrtoip(bytes) + '/' + bits, bytes, bits, attributes: [] };
}

function parse_entry(kind, raw, detailed) {
    return kind == 'geosite' ? domain_entry(raw, detailed) : network_entry(raw, detailed);
}

function public_entry(entry) {
    return { type: entry.type, value: entry.value, attributes: entry.attributes };
}

function text_match(value, query, pattern, sensitive) {
    if (pattern) return match(value, pattern) != null;
    return index(sensitive ? value : lc(value), sensitive ? query : lc(query)) >= 0;
}

function ip_contains(entry, addr) {
    if (length(entry.bytes) != length(addr)) return false;
    let count = int(entry.bits / 8), remain = entry.bits % 8;
    for (let i = 0; i < count; i++)
        if (entry.bytes[i] != addr[i]) return false;
    if (remain) {
        let mask = (255 << (8 - remain)) & 255;
        if ((entry.bytes[count] & mask) != (addr[count] & mask)) return false;
    }
    return true;
}

function domain_matches(entry, name) {
    let value = lc(entry.value);
    if (!value) return false;
    if (entry.type == 'full') return name == value;
    if (entry.type == 'keyword') return index(name, value) >= 0;
    if (entry.type == 'domain')
        return name == value || (length(name) > length(value) &&
            substr(name, -(length(value) + 1)) == '.' + value);
    // Xray uses RE2, which is not interchangeable with ucode's POSIX ERE.
    return false;
}

function list_categories(kind) {
    let source = source_info(kind), indexed = load_index(source);
    return { ok: true, kind, path: source.path, size: source.size,
             mtime: source.mtime, categories: indexed.categories };
}

function browse(kind, tag, page_arg, filter_arg, type_arg) {
    let source = source_info(kind), indexed = load_index(source);
    tag = lc(trim('' + (tag ?? '')));
    if (!tag || length(tag) > 128) die('invalid category');
    let page = int(page_arg || '0');
    if (page < 0 || page > 100000) die('invalid page number');
    let filter = trim('' + (filter_arg ?? ''));
    if (length(filter) > 256) die('entry filter is too long');
    let type_filter = '' + (type_arg ?? '');
    if (type_filter != '' && type_filter != 'all' &&
        index('|keyword|regexp|domain|full|cidr|', '|' + type_filter + '|') < 0)
        die('invalid entry type filter');

    let category = null;
    for (let item in indexed.categories)
        if (item.name == tag) { category = item; break; }
    if (!category) die('category not found: ' + tag);

    let offset = page * PAGE_SIZE, count = 0, entries = [], filtered = !!filter ||
        (type_filter && type_filter != 'all');
    let file = fs.open(source.path, 'r');
    if (!file) die('cannot open GeoData file: ' + source.path);
    try {
        for (let group in indexed.groups) {
            if (group.name != tag) continue;
            // Search terms absent from the raw category cannot match any entry.
            let raw = read_group(file, group, source.size);
            if (filter && index(lc(raw), lc(filter)) < 0) continue;
            visit_entries(raw, function(data) {
                let entry = parse_entry(kind, data);
                if (type_filter && type_filter != 'all' && entry.type != type_filter) return;
                if (filter && !text_match(entry.value, filter, null, false)) return;
                if (count >= offset && length(entries) < PAGE_SIZE) push(entries, public_entry(entry));
                count++;
            });
        }
    } catch (e) { file.close(); die('cannot browse GeoData: ' + e); }
    file.close();
    return { ok: true, kind, category: tag, inverse: category.inverse,
             total: filtered ? count : category.count, page,
             page_size: PAGE_SIZE, entries };
}

// For domain/full/keyword rules, a match requires the rule's complete value to
// be a substring of the queried hostname. GeoSite's protobuf Domain.value is
// field 2 (wire type 2), encoded as 0x12 + length + value. Checking these bytes
// first avoids parsing thousands of unrelated categories. Queries above 24
// bytes use the normal scanner to bound the number of generated substrings.
function domain_value_needles(domain) {
    if (length(domain) > 24) return null;
    let seen = {}, needles = [];
    for (let size = 1; size <= length(domain); size++) {
        for (let i = 0; i + size <= length(domain); i++) {
            let part = substr(domain, i, size);
            if (seen[part]) continue;
            seen[part] = true;
            push(needles, chr(18, size) + part);
        }
    }
    return needles;
}

function may_contain_domain_match(raw, needles) {
    let lower = lc(raw);
    for (let needle in needles)
        if (index(lower, needle) >= 0) return true;
    return false;
}

function search_entries(kind, query_arg, mode_arg, regex_arg, sensitive_arg,
                        group_arg, position_arg, within_arg) {
    let source = source_info(kind), indexed = load_index(source);
    let query = trim('' + (query_arg ?? ''));
    let mode = '' + (mode_arg || 'match');
    let regex = regex_arg == '1', sensitive = sensitive_arg == '1';
    if (!query || length(query) > 256) die('query must contain 1 to 256 characters');
    if (mode != 'match' && mode != 'text') die('invalid search mode');
    if (regex && mode != 'text') die('regular expression search requires text mode');
    if (regex && length(query) > 128) die('regular expression is too long');

    let pattern = regex ? regexp(query, sensitive ? '' : 'i') : null;
    let address = null, domain = '';
    if (mode == 'match' && kind == 'geoip') {
        address = iptoarr(query);
        if (!address || (length(address) != 4 && length(address) != 16))
            die('enter a valid IPv4 or IPv6 address');
    }
    if (mode == 'match' && kind == 'geosite') {
        if (length(query) > 253 || !match(query, /^[A-Za-z0-9_.-]+$/) ||
            substr(query, 0, 1) == '.' || substr(query, -1) == '.')
            die('enter a valid domain name');
        domain = lc(query);
    }

    let domain_needles = mode == 'match' && kind == 'geosite' ? domain_value_needles(domain) : null;
    let group_index = int(group_arg || '0'), position = int(position_arg || '0');
    let carry_within = within_arg == '1';
    if (group_index < 0 || group_index > length(indexed.groups) || position < 0 ||
        position > MAX_ENTRY_SIZE) die('invalid GeoData search cursor');
    if (group_index == length(indexed.groups) && position) die('invalid GeoData search cursor');

    let results = [], total = 0, category_total = 0, skipped_regex = 0;
    let scanned = 0, group_work = 0, partial = 0;
    let file = fs.open(source.path, 'r');
    if (!file) die('cannot open GeoData file: ' + source.path);
    try {
        while (group_index < length(indexed.groups) &&
               scanned < SEARCH_BATCH_ENTRIES && group_work < 100) {
            let group = indexed.groups[group_index];
            let raw = read_group(file, group, source.size);
            if (position > length(raw)) die('invalid GeoData search cursor position');

            if (position == 0 &&
                ((mode == 'text' && !regex &&
                  index(sensitive ? raw : lc(raw), sensitive ? query : lc(query)) < 0) ||
                 (domain_needles && !may_contain_domain_match(raw, domain_needles)))) {
                group_index++;
                group_work++;
                continue;
            }

            let reader = string_reader(raw), hits = 0, matches = [];
            let within = position > 0 ? carry_within : false;
            reader.pos = position;
            while (reader.pos < length(raw) && scanned < SEARCH_BATCH_ENTRIES) {
                let item = field(reader, length(raw));
                if (item.number != 2 || item.wire != 2) continue;
                let entry = parse_entry(kind, item.value, mode == 'text');
                scanned++;
                let matched = false;

                if (mode == 'text') {
                    matched = text_match(entry.value, query, pattern, sensitive);
                } else if (kind == 'geoip') {
                    matched = ip_contains(entry, address);
                    if (matched) within = true;
                } else if (entry.type == 'regexp') {
                    skipped_regex++;
                } else {
                    matched = domain_matches(entry, domain);
                }

                if (matched && !(kind == 'geoip' && mode == 'match' && group.inverse)) {
                    hits++;
                    if (length(matches) < PREVIEW_SIZE)
                        push(matches, public_entry(parse_entry(kind, item.value)));
                }
            }

            let complete = reader.pos >= length(raw);
            if (complete && kind == 'geoip' && mode == 'match' && group.inverse && !within) {
                hits = 1;
                matches = [{ type: 'inverse', value: 'Address is outside the listed CIDRs', attributes: [] }];
            }

            if (hits) {
                total += hits;
                category_total++;
                if (length(results) < MAX_RESULT_GROUPS)
                    push(results, { name: group.name, total: hits, inverse: group.inverse, matches });
            }
            if (complete) {
                group_index++;
                position = 0;
                carry_within = false;
                group_work++;
            } else {
                position = reader.pos;
                carry_within = within;
                partial = length(raw) ? position / length(raw) : 0;
                break;
            }
        }
    } catch (e) { file.close(); die('cannot search GeoData: ' + e); }
    file.close();

    return {
        ok: true, kind, query, mode, total, category_total, scanned, skipped_regex,
        categories: results, total_groups: length(indexed.groups),
        next_group: group_index, next_position: position,
        next_within: carry_within ? '1' : '0',
        progress: (group_index + partial) / (length(indexed.groups) || 1),
        done: group_index >= length(indexed.groups)
    };
}

function dispatch(command, args) {
    if (command == 'geodata-list') return list_categories(args[0] || '');
    if (command == 'geodata-browse')
        return browse(args[0] || '', args[1] || '', args[2] || '0',
                      args[3] || '', args[4] || '');
    if (command == 'geodata-search')
        return search_entries(args[0] || '', args[1] || '', args[2] || 'match',
                              args[3] || '0', args[4] || '0',
                              args[5] || '0', args[6] || '0', args[7] || '0');
    return { ok: false, error: 'unsupported GeoData command' };
}

let result;
try { result = dispatch(ARGV[0] || '', slice(ARGV, 1)); }
catch (e) { result = { ok: false, error: '' + e }; }
printf('%J\n', result);
exit(result?.ok === false ? 1 : 0);
