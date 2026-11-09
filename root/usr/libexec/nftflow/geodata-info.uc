#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0
// Only provide metadata and a narrowly ACL-scoped download alias.
// Parsing and searching are performed in the administrator's browser.

'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const RUNTIME = '/var/run/nftflow';
const ALIASES = RUNTIME + '/geodata';
const MAX_FILE_SIZE = 128 * 1024 * 1024;

function ensure_directory(path, mode) {
    let state = fs.stat(path);
    if (!state) {
        if (fs.mkdir(path, mode) !== true)
            die('cannot create GeoData directory ' + path);
        state = fs.stat(path);
    }
    if (!state || state.type != 'directory')
        die('invalid GeoData directory ' + path);
    if (path == ALIASES && fs.chmod(path, 0o700) !== true)
        die('cannot secure GeoData directory ' + path);
}

function file_info(kind) {
    if (kind != 'geosite' && kind != 'geoip')
        die('unsupported GeoData type');

    let option = kind == 'geosite' ? 'geosite_file' : 'geoip_file';
    let path = cursor().get('nftflow', 'main', option);
    if (!path)
        die(option + ' is not configured in Settings');
    if (substr(path, 0, 1) != '/')
        die(option + ' must be an absolute path');

    let source = fs.stat(path);
    if (!source || source.type != 'file')
        die('cannot read ' + kind + ' file: ' + path);
    if (source.size > MAX_FILE_SIZE)
        die(kind + ' file exceeds the 128 MiB browser limit');

    ensure_directory(RUNTIME, 0o755);
    ensure_directory(ALIASES, 0o700);

    // The ACL names only these two aliases, never the configured source path.
    // Both directory and symlinks are controlled by root.
    let alias = ALIASES + '/' + kind + '.dat';
    if (fs.readlink(alias) != path) {
        let staging = fs.mkdtemp(ALIASES + '/link-XXXXXX');
        if (!staging)
            die('cannot prepare GeoData download alias');
        let temporary = staging + '/file';
        let error = null;
        try {
            if (fs.symlink(path, temporary) !== true ||
                fs.rename(temporary, alias) !== true)
                error = 'cannot publish GeoData download alias';
        } catch (e) {
            error = 'cannot publish GeoData download alias: ' + e;
        }
        // ucode requires catch after try; keep cleanup outside the block.
        fs.unlink(temporary);
        fs.rmdir(staging);
        if (error)
            die(error);
    }

    return {
        ok: true, kind, source: path, read_path: alias,
        size: source.size, mtime: source.mtime, ctime: source.ctime
    };
}

let result;
try { result = file_info(ARGV[0] || ''); }
catch (e) { result = { ok: false, error: '' + e }; }
printf('%J\n', result);
exit(result.ok ? 0 : 1);
