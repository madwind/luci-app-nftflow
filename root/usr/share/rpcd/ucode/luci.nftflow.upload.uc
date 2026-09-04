#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0
// Non-blocking RPC bridge for locally uploaded GeoIP/GeoSite data.

'use strict';

let ubus = require('ubus').connect();

const IMPORTER = '/usr/libexec/nftflow/geodata-import.uc';

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
    return { ok: false, error: trim(output || '') || 'GeoData importer returned no JSON' };
}

function exec_result(code, reply) {
    if (code !== UBUS_STATUS_OK)
        return { ok: false, error: `GeoData import request failed with ubus status ${code}` };
    if (type(reply) != 'object')
        return { ok: false, error: 'GeoData importer returned no execution result' };

    let stdout = `${reply.stdout || ''}`;
    let stderr = trim(`${reply.stderr || ''}`);
    let exit_code = int(reply.code || 0);
    let result = parse_result(stdout);

    if (exit_code !== 0 && result.ok === true)
        return { ok: false, error: stderr || `GeoData importer exited with status ${exit_code}` };
    if (result.ok === false && stderr && !result.detail)
        result.detail = stderr;
    return result;
}

function defer_import(request, kind) {
    if (kind != 'geoip' && kind != 'geosite')
        return { ok: false, error: 'kind must be geoip or geosite' };
    if (!ubus)
        return { ok: false, error: 'unable to connect to ubus' };

    try {
        return ubus.defer('file', 'exec', {
            command: '/usr/bin/ucode',
            params: [ IMPORTER, kind ]
        }, function(code, reply) {
            let result;
            try {
                result = exec_result(code, reply);
            } catch (e) {
                result = { ok: false, error: `GeoData import: ${e}` };
            }
            request.reply(result, UBUS_STATUS_OK);
        });
    } catch (e) {
        return { ok: false, error: `GeoData import: ${e}` };
    }
}

return {
    'luci.nftflow.upload': {
        import: {
            args: { kind: 'geoip' },
            call: request => defer_import(request, request && request.args ? request.args.kind : '')
        }
    }
};
