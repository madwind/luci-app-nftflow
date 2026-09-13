'use strict';

import { open } from 'fs';

const DEFAULT_FIREWALL = '/usr/share/nftflow/defaults/firewall.nft';
const DEFAULT_ROUTING = '/usr/share/nftflow/defaults/routing.conf';

function readDefault(path, label) {
    let file = open(path, 'r');
    if (!file)
        return { ok: false, error: `Default ${label} template is unavailable.` };

    let config = file.read('all') || '';
    file.close();
    return { ok: true, path, config };
}

return {
    'luci.nftflow.defaults': {
        firewall: {
            args: {},
            call: function() {
                return readDefault(DEFAULT_FIREWALL, 'Firewall');
            }
        },
        routing: {
            args: {},
            call: function() {
                return readDefault(DEFAULT_ROUTING, 'Routing');
            }
        }
    }
};
