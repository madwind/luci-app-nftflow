#!/usr/bin/env ucode
// SPDX-License-Identifier: Apache-2.0

'use strict';

import { popen } from 'fs';

const PACKAGE = 'luci-app-nftflow';

function version() {
    let process = popen(`apk query --from installed --format json --fields version ${PACKAGE} 2>/dev/null`, 'r');
    if (!process)
        return { ok: false, error: 'unable to query installed package metadata' };

    let output = process.read('all') || '';
    let code = process.close();
    if (code !== true && code !== 0)
        return { ok: false, error: trim(output || '') || 'apk query failed' };

    let packages;
    try { packages = json(output); }
    catch (e) { return { ok: false, error: 'apk returned invalid package metadata' }; }

    if (type(packages) != 'array' || length(packages) != 1 || type(packages[0]) != 'object')
        return { ok: false, error: 'installed package metadata is unavailable' };

    let installed = trim(`${packages[0].version || ''}`);
    if (!installed || !match(installed, /^[A-Za-z0-9._+~-]+$/))
        return { ok: false, error: 'installed package version is invalid' };

    return { ok: true, version: installed };
}

return {
    'luci.nftflow.package': {
        version: {
            args: {},
            call: () => version()
        }
    }
};
