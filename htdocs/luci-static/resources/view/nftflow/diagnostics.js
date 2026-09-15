'use strict';
'require view';
'require rpc';
'require ui';
'require nftflow.ui as nftflowUi';

var callDiagnosticDns = rpc.declare({
    object: 'luci.nftflow',
    method: 'diagnostic_dns',
    params: [ 'source', 'domain' ],
    expect: { '': {} },
    reject: true
});

var callDiagnosticRequest = rpc.declare({
    object: 'luci.nftflow',
    method: 'diagnostic_request',
    params: [ 'domain' ],
    expect: { '': {} },
    reject: true
});

var callDiagnosticFirewall = rpc.declare({
    object: 'luci.nftflow',
    method: 'diagnostic_firewall',
    params: [ 'address' ],
    expect: { '': {} },
    reject: true
});

var LOG_SOURCE = /^(?:nftflow|nftflowctl)(?:\[\d+\])?:\s*/i;
var TARGET_PATTERNS = [
    /\b(?:accepted|rejected)\s+(?:tcp|udp):(\[[0-9A-Fa-f:.]+\]|(?:\d{1,3}\.){3}\d{1,3})(?::\d+)?/ig,
    /\b(?:dialing|dial|connecting to|opening connection to)\s+(?:tcp|udp):(\[[0-9A-Fa-f:.]+\]|(?:\d{1,3}\.){3}\d{1,3})(?::\d+)?/ig,
    /\b(?:target|destination|remote)\s*[=:]\s*(\[[0-9A-Fa-f:.]+\]|(?:\d{1,3}\.){3}\d{1,3})(?::\d+)?/ig
];
var ROUTE_RE = /\[([^\[\]]+?)\s*->\s*([^\[\]]+?)\]/g;
var REQUEST_LOG_GRACE_MS = 1500;

function delay(ms) {
    return new Promise(function(resolve) { window.setTimeout(resolve, ms); });
}

function formatLogEntry(entry) {
    var message = entry && entry.msg != null ? String(entry.msg) : '';
    return message.replace(LOG_SOURCE, '').replace(/^nftflow:\s*/i, '');
}

function isRuntimeEntry(entry) {
    var message = entry && entry.msg != null ? String(entry.msg) : '';
    return LOG_SOURCE.test(message);
}

function validDomain(value) {
    return /^[A-Za-z0-9_.-]+$/.test(value) && value.length <= 253 && value.charAt(0) !== '.' && value.charAt(value.length - 1) !== '.';
}

function normalizeEndpoint(value) {
    value = String(value || '');
    if (value.charAt(0) === '[' && value.charAt(value.length - 1) === ']')
        value = value.slice(1, -1);
    return value;
}

function extractTargetAddresses(line) {
    var found = Object.create(null);
    TARGET_PATTERNS.forEach(function(pattern) {
        var match;
        pattern.lastIndex = 0;
        while ((match = pattern.exec(line)) !== null)
            found[normalizeEndpoint(match[1])] = true;
    });
    return Object.keys(found);
}

function extractRoutes(line) {
    var found = Object.create(null);
    var match;
    ROUTE_RE.lastIndex = 0;
    while ((match = ROUTE_RE.exec(line)) !== null) {
        var inbound = match[1].trim();
        var outbound = match[2].trim();
        if (inbound && outbound)
            found['%s -> %s'.format(inbound, outbound)] = true;
    }
    return Object.keys(found);
}

function uniqueAddresses(results) {
    var seen = Object.create(null);
    var values = [];
    (results || []).forEach(function(result) {
        (result && Array.isArray(result.addresses) ? result.addresses : []).forEach(function(item) {
            var address = item && item.address ? String(item.address) : '';
            if (!address || seen[address]) return;
            seen[address] = true;
            values.push(address);
        });
    });
    return values;
}

function relatedTrace(lines, domain, seedAddresses) {
    var known = Object.create(null);
    var selected = Object.create(null);
    var targets = Object.create(null);
    var normalizedDomain = domain.toLowerCase();
    var changed = true;

    (seedAddresses || []).forEach(function(address) { known[address] = true; });

    while (changed) {
        changed = false;
        lines.forEach(function(line, index) {
            if (selected[index]) return;

            var lower = line.toLowerCase();
            var related = lower.indexOf(normalizedDomain) >= 0;
            if (!related) {
                Object.keys(known).some(function(address) {
                    if (line.indexOf(address) >= 0) {
                        related = true;
                        return true;
                    }
                    return false;
                });
            }
            if (!related) return;

            selected[index] = true;
            extractTargetAddresses(line).forEach(function(address) {
                targets[address] = true;
                if (!known[address]) {
                    known[address] = true;
                    changed = true;
                }
            });
        });
    }

    return {
        lines: lines.filter(function(line, index) { return !!selected[index]; }),
        targets: Object.keys(targets)
    };
}

function routesForTarget(lines, address) {
    var found = Object.create(null);
    lines.forEach(function(line) {
        if (line.indexOf(address) < 0) return;
        extractRoutes(line).forEach(function(route) { found[route] = true; });
    });
    if (!Object.keys(found).length)
        lines.forEach(function(line) { extractRoutes(line).forEach(function(route) { found[route] = true; }); });
    return Object.keys(found);
}

function firewallNodes(result) {
    if (!result || result.ok !== true)
        return [ E('span', { 'class': 'error' }, _('Lookup failed')) ];
    if (!Array.isArray(result.matches) || !result.matches.length)
        return [ E('span', { 'style': 'opacity:.7;' }, _('No set match')) ];

    return result.matches.map(function(match) {
        var detail = [ match.family || '', match.table || '' ].filter(Boolean).join(' ');
        if (match.expires)
            detail += (detail ? ' · ' : '') + match.expires;
        return E('div', { 'style': 'margin:.1rem 0;' }, [
            E('code', {}, '@' + (match.set || '')),
            detail ? E('span', { 'style': 'margin-left:.4rem; opacity:.7; font-size:90%;' }, detail) : ''
        ]);
    });
}

function lookupFirewall(addresses) {
    var results = Object.create(null);
    var chain = Promise.resolve();
    addresses.forEach(function(address) {
        chain = chain.then(function() {
            return callDiagnosticFirewall(address).then(function(result) {
                results[address] = result;
            }).catch(function(error) {
                results[address] = { ok: false, error: nftflowUi.errorMessage(error) };
            });
        });
    });
    return chain.then(function() { return results; });
}

function table(headers, rows) {
    return E('div', { 'style': 'overflow-x:auto;' }, [
        E('table', { 'class': 'table', 'style': 'width:100%; margin-top:.5rem;' }, [
            E('thead', {}, [
                E('tr', {}, headers.map(function(header) {
                    return E('th', { 'style': 'text-align:left;' }, header);
                }))
            ]),
            E('tbody', {}, rows)
        ])
    ]);
}

function addressTable(result, firewall) {
    var addresses = result && Array.isArray(result.addresses) ? result.addresses : [];
    if (!addresses.length)
        return E('div', { 'class': 'notice', 'style': 'margin-top:.5rem;' }, result && result.detail ? result.detail : _('No address returned.'));

    return table([ _('Type'), _('Address'), _('Firewall set') ], addresses.map(function(item) {
        var address = item.address;
        return E('tr', {}, [
            E('td', {}, item.family === 6 ? 'AAAA' : 'A'),
            E('td', {}, E('code', {}, address)),
            E('td', {}, firewallNodes(firewall[address]))
        ]);
    }));
}

function dnsCard(title) {
    var state = E('span', {}, _('Pending'));
    var body = E('div');
    return {
        root: E('div', { 'class': 'cbi-section', 'style': 'flex:1 1 22rem; min-width:0;' }, [
            E('h4', { 'style': 'margin-top:0;' }, title),
            state,
            body
        ]),
        state: state,
        body: body
    };
}

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    render: function() {
        var domainInput = E('input', {
            'class': 'cbi-input-text',
            'type': 'text',
            'placeholder': 'example.com',
            'autocomplete': 'off',
            'spellcheck': 'false',
            'style': 'min-width:20rem; flex:1 1 20rem;'
        });
        var checkButton = E('button', { 'class': 'btn cbi-button cbi-button-action', 'type': 'button' }, _('Check'));
        var overallState = E('span', { 'aria-live': 'polite' });
        var logState = E('span', { 'aria-live': 'polite' }, _('Connecting runtime log...'));

        var lanCard = dnsCard(_('LAN DNS'));
        var routerCard = dnsCard(_('Router DNS'));
        var dohCard = dnsCard(_('DoH 1.1.1.1'));

        var requestState = E('span');
        var requestSummary = E('div');
        var traceOutput = E('textarea', {
            'class': 'cbi-input-text',
            'style': 'display:block; width:100%; min-height:18em; box-sizing:border-box; white-space:pre-wrap; overflow-wrap:anywhere;',
            'rows': 16,
            'wrap': 'soft',
            'spellcheck': 'false',
            'readonly': true
        });

        var streamController = null;
        var activeCapture = null;
        var streamReady = false;

        function appendEntry(entry) {
            if (!isRuntimeEntry(entry) || !activeCapture) return;
            activeCapture.lines.push(formatLogEntry(entry));
        }

        function consumeFrame(frame) {
            var eventName = 'message';
            var data = [];
            frame.split('\n').forEach(function(line) {
                if (!line || line.charAt(0) === ':') return;
                if (line.indexOf('event:') === 0) eventName = line.slice(6).trim();
                else if (line.indexOf('data:') === 0) data.push(line.slice(5).trimStart());
            });
            if (eventName !== 'message' || !data.length) return;
            try { appendEntry(JSON.parse(data.join('\n'))); } catch (error) { console.warn(error); }
        }

        function pump(reader, decoder, state, controller) {
            return reader.read().then(function(chunk) {
                if (chunk.done) throw new Error('log subscription ended');
                state.buffer += decoder.decode(chunk.value, { stream: true }).replace(/\r\n/g, '\n');
                var boundary;
                while ((boundary = state.buffer.indexOf('\n\n')) >= 0) {
                    consumeFrame(state.buffer.slice(0, boundary));
                    state.buffer = state.buffer.slice(boundary + 2);
                }
                if (!controller.signal.aborted)
                    return pump(reader, decoder, state, controller);
            });
        }

        function startLogStream() {
            if (streamController || typeof fetch !== 'function' || typeof TextDecoder !== 'function' || typeof AbortController !== 'function')
                return Promise.resolve(streamReady);

            var controller = new AbortController();
            streamController = controller;
            nftflowUi.setState(logState, 'notice', _('Connecting runtime log...'));

            return fetch('/ubus/subscribe/log', {
                method: 'GET',
                headers: { 'Accept': 'text/event-stream', 'Authorization': 'Bearer ' + rpc.getSessionID() },
                credentials: 'same-origin', cache: 'no-store', signal: controller.signal
            }).then(function(response) {
                if (!response.ok || !response.body)
                    throw new Error('log subscription HTTP ' + response.status);
                streamReady = true;
                nftflowUi.setState(logState, 'ok', _('Runtime log live'));
                pump(response.body.getReader(), new TextDecoder(), { buffer: '' }, controller).catch(function(error) {
                    if (!controller.signal.aborted) {
                        streamReady = false;
                        nftflowUi.setState(logState, 'error', error.message || String(error));
                    }
                });
                return true;
            }).catch(function(error) {
                streamController = null;
                streamReady = false;
                nftflowUi.setState(logState, 'error', error.message || String(error));
                return false;
            });
        }

        function runDns(source, domain, card) {
            nftflowUi.setState(card.state, 'notice', _('Running...'));
            card.body.replaceChildren();
            return callDiagnosticDns(source, domain).then(function(result) {
                if (result && result.ok === true)
                    nftflowUi.setState(card.state, 'ok', result.resolver ? _('Resolver: %s').format(result.resolver) : _('Done'));
                else
                    nftflowUi.setState(card.state, 'warn', result && (result.error || result.detail) ? (result.error || result.detail) : _('Query failed'));
                return result || { ok: false, addresses: [] };
            }).catch(function(error) {
                nftflowUi.setState(card.state, 'error', nftflowUi.errorMessage(error));
                return { ok: false, addresses: [], detail: nftflowUi.errorMessage(error) };
            });
        }

        function renderDns(result, card, firewall) {
            card.body.replaceChildren(addressTable(result, firewall));
        }

        function renderRequest(trace, firewall) {
            if (!trace.targets.length) {
                requestSummary.replaceChildren(E('div', { 'class': 'notice', 'style': 'margin-top:.5rem;' }, _('No remote target IP was found in the related Xray runtime log.')));
                return;
            }

            requestSummary.replaceChildren(table([ _('Target IP'), _('Firewall set'), _('Xray route') ], trace.targets.map(function(address) {
                var routes = routesForTarget(trace.lines, address);
                return E('tr', {}, [
                    E('td', {}, E('code', {}, address)),
                    E('td', {}, firewallNodes(firewall[address])),
                    E('td', {}, routes.length ? routes.map(function(route) { return E('div', {}, E('code', {}, route)); }) : '—')
                ]);
            })));
        }

        function runCheck() {
            var domain = domainInput.value.trim();
            if (!validDomain(domain)) {
                nftflowUi.setState(overallState, 'error', _('Enter a valid domain name.'));
                return Promise.resolve();
            }

            checkButton.disabled = true;
            nftflowUi.setState(overallState, 'notice', _('Running diagnostics...'));
            requestSummary.replaceChildren();
            traceOutput.value = '';
            nftflowUi.setState(requestState, 'notice', _('Pending'));

            return startLogStream().then(function(ready) {
                if (!ready) throw new Error(_('Runtime log subscription is unavailable.'));

                activeCapture = { lines: [], requestStart: 0 };
                var dnsResults = [];

                return runDns('lan', domain, lanCard).then(function(result) {
                    dnsResults.push(result);
                    return runDns('router', domain, routerCard);
                }).then(function(result) {
                    dnsResults.push(result);
                    return runDns('doh', domain, dohCard);
                }).then(function(result) {
                    dnsResults.push(result);
                    activeCapture.requestStart = activeCapture.lines.length;
                    nftflowUi.setState(requestState, 'notice', _('Requesting https://%s/ ...').format(domain));
                    return callDiagnosticRequest(domain).catch(function(error) {
                        return { ok: false, detail: nftflowUi.errorMessage(error) };
                    });
                }).then(function(requestResult) {
                    nftflowUi.setState(requestState, requestResult && requestResult.ok === true ? 'ok' : 'warn',
                        requestResult && requestResult.ok === true ? _('Page request completed') : ((requestResult && requestResult.detail) || _('Page request failed')));
                    return delay(REQUEST_LOG_GRACE_MS).then(function() { return requestResult; });
                }).then(function() {
                    var requestLines = activeCapture.lines.slice(activeCapture.requestStart);
                    var dnsAddresses = uniqueAddresses(dnsResults);
                    var trace = relatedTrace(requestLines, domain, dnsAddresses);
                    var allAddresses = dnsAddresses.slice();
                    trace.targets.forEach(function(address) {
                        if (allAddresses.indexOf(address) < 0) allAddresses.push(address);
                    });

                    return lookupFirewall(allAddresses).then(function(firewall) {
                        renderDns(dnsResults[0], lanCard, firewall);
                        renderDns(dnsResults[1], routerCard, firewall);
                        renderDns(dnsResults[2], dohCard, firewall);
                        renderRequest(trace, firewall);

                        traceOutput.value = trace.lines.length ? trace.lines.join('\n') : _('No related Xray runtime log lines were captured.');
                        nftflowUi.setState(overallState, 'ok', _('Diagnostics complete'));
                    });
                });
            }).catch(function(error) {
                nftflowUi.setState(overallState, 'error', nftflowUi.errorMessage(error));
            }).finally(function() {
                activeCapture = null;
                checkButton.disabled = false;
            });
        }

        checkButton.addEventListener('click', ui.createHandlerFn(checkButton, runCheck));
        domainInput.addEventListener('keydown', function(event) {
            if (event.key === 'Enter') {
                event.preventDefault();
                checkButton.click();
            }
        });

        window.addEventListener('pagehide', function() {
            if (streamController) streamController.abort();
            streamController = null;
            streamReady = false;
        }, { once: true });

        window.setTimeout(startLogStream, 0);

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, _('Diagnostics')),
            E('div', { 'class': 'cbi-section-descr' }, _('Compare LAN DNS, router-local DNS and DoH, then trace an actual HTTPS request through the live Xray runtime log and locate every related IP in the active firewall sets.')),
            E('div', { 'class': 'cbi-section' }, [
                E('div', { 'style': 'display:flex; flex-wrap:wrap; gap:.5rem; align-items:center;' }, [ domainInput, checkButton, overallState ]),
                E('div', { 'style': 'margin-top:.5rem;' }, logState)
            ]),
            E('h3', {}, _('DNS comparison')),
            E('div', { 'style': 'display:flex; flex-wrap:wrap; gap:1rem; align-items:stretch;' }, [ lanCard.root, routerCard.root, dohCard.root ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Actual request')),
                requestState,
                requestSummary
            ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Xray request trace')),
                traceOutput
            ])
        ]);
    }
});