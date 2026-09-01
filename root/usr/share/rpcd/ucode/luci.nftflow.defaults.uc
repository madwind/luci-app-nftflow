'use strict';

import { open } from 'fs';

const DEFAULT_FIREWALL = '/usr/share/nftflow/defaults/firewall.nft';

function readDefaultFirewall() {
    let file = open(DEFAULT_FIREWALL, 'r');
    if (!file)
        return { ok: false, error: 'Default Firewall template is unavailable.' };

    let config = file.read('all') || '';
    file.close();
    return { ok: true, path: DEFAULT_FIREWALL, config: config };
}

return {
    'luci.nftflow.defaults': {
        firewall: {
            args: {},
            call: function() {
                return readDefaultFirewall();
            }
        }
    }
};
