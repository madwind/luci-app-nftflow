#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0

'use strict';

import { cursor } from 'uci';

let ubus = require('ubus').connect();

const FETCH = '/bin/uclient-fetch';
const METRICS_TIMEOUT_SECONDS = 2;

function uci_get(option, fallback) {
    let ctx = cursor(), value = null;
    try { value = ctx.get('nftflow', 'main', option); } catch (e) {}
    return value == null || `${value}` == '' ? fallback : `${value}`;
}

function hidden_result(error) {
    let result = { ok: true, available: false, inbounds: [], outbounds: [] };
    if (error) result.error = `${error}`;
    return result;
}

function metric_group(group) {
    let rows = [], complete = true;
    if (type(group) != 'object') return { rows, complete: false };

    for (let tag, counters in group) {
        if (type(counters) != 'object') continue;
        if (!('uplink' in counters) || !('downlink' in counters)) complete = false;

        let uplink = int(counters.uplink || 0);
        let downlink = int(counters.downlink || 0);
        if (uplink < 0) uplink = 0;
        if (downlink < 0) downlink = 0;
        push(rows, { tag: `${tag}`, uplink, downlink });
    }

    return { rows, complete: complete && length(rows) > 0 };
}

function json_path(document, path) {
    let value = document;
    let parts = split(trim(`${path || ''}`), '.');
    if (!length(parts)) return null;

    for (let key in parts) {
        key = trim(`${key || ''}`);
        if (!key || type(value) != 'object' || !(key in value)) return null;
        value = value[key];
    }

    return value;
}

function extract_json_counters(output, inbound_path, outbound_path) {
    let document;
    try { document = json(`${output || ''}`); }
    catch (e) { return null; }

    if (type(document) != 'object') return null;

    let inbounds = metric_group(json_path(document, inbound_path));
    let outbounds = metric_group(json_path(document, outbound_path));
    if (!inbounds.complete || !outbounds.complete)
        return hidden_result('traffic counters are missing or incomplete at the configured JSON paths');

    return { ok: true, available: true, inbounds: inbounds.rows, outbounds: outbounds.rows };
}

function valid_url(url) {
    return match(`${url || ''}`, /^https?:\/\//) != null;
}

function traffic(request) {
    if (!ubus) return hidden_result('unable to connect to ubus');

    let url = trim(uci_get('metrics_url', ''));
    let inbound_path = trim(uci_get('metrics_inbound_path', ''));
    let outbound_path = trim(uci_get('metrics_outbound_path', ''));
    if (!url) return hidden_result();
    if (!valid_url(url)) return hidden_result('metrics URL must use HTTP or HTTPS');
    if (!inbound_path || !outbound_path) return hidden_result('metrics JSON paths must not be empty');

    try {
        return ubus.defer('file', 'exec', {
            command: FETCH,
            params: [ `--timeout=${METRICS_TIMEOUT_SECONDS}`, '-q', '-O', '-', url ]
        }, function(code, reply) {
            let result = null;
            if (code === UBUS_STATUS_OK && type(reply) == 'object' && int(reply.code || 0) === 0)
                result = extract_json_counters(reply.stdout, inbound_path, outbound_path);

            request.reply(result || hidden_result('metrics endpoint did not return supported traffic data'), UBUS_STATUS_OK);
        });
    } catch (e) {
        return hidden_result(`${e}`);
    }
}

return {
    'luci.nftflow.metrics': {
        traffic: {
            args: {},
            call: request => traffic(request)
        }
    }
};
