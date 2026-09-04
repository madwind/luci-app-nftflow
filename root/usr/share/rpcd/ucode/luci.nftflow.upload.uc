#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0
// RPC bridge for locally uploaded GeoIP/GeoSite data.

'use strict';

import { popen } from 'fs';

const IMPORTER = '/usr/libexec/nftflow/geodata-import.uc';

function shellquote(value) { return "'" + replace(`${value == null ? '' : value}`, /'/g, "'\\''") + "'"; }
function parse_result(output) {
    let lines = split(trim(output || ''), /\r?\n/);
    for (let i = length(lines) - 1; i >= 0; i--) {
        if (!trim(lines[i])) continue;
        try { return json(trim(lines[i])); } catch (e) {}
    }
    return { ok: false, error: trim(output || 'GeoData importer returned no JSON') };
}
function run_import(kind) {
    if (kind != 'geoip' && kind != 'geosite') return { ok: false, error: 'kind must be geoip or geosite' };
    let fd = popen(`/usr/bin/ucode ${IMPORTER} ${shellquote(kind)} 2>&1`, 'r');
    if (!fd) return { ok: false, error: 'unable to start GeoData importer' };
    let output = fd.read('all') || '';
    let rc = fd.close();
    let result = parse_result(output);
    if (rc !== 0 && result.ok === true) return { ok: false, error: trim(output || 'GeoData importer failed') };
    return result;
}

return {
    'luci.nftflow.upload': {
        import: {
            args: { kind: 'geoip' },
            call: request => run_import(request && request.args ? request.args.kind : '')
        }
    }
};
