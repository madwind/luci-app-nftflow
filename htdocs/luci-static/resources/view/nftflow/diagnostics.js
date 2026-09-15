'use strict';
'require view';
'require rpc';
'require ui';
'require nftflow.ui as nftflowUi';

var callDiagnosticDns = rpc.declare({
    object: 'luci.nftflow',
    method: 'diagnostic_dns',
    params: [ 'source', 'domain', 'resolver' ],
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
var DOH_RESOLVERS = [
    { name: 'Cloudflare', resolver: '1.1.1.1' },
    { name: 'Google', resolver: '8.8.8.8' },
    { name: 'AliDNS', resolver: '223.5.5.5' }
];

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

function seenInDns(address, sources) {
    var seen = [];
    (sources || []).forEach(function(source) {
        var addresses = source.result && Array.isArray(source.result.addresses) ? source.result.addresses : [];
        if (addresses.some(function(item) { return item && item.address === address; }))
            seen.push(source.label);
    });
    return seen;
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

function lookupFirewall(addresses, results) {
    results = results || Object.create(null);
    var chain = Promise.resolve();
    addresses.forEach(function(address) {
        if (Object.prototype.hasOwnProperty.call(results, address)) return;
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

function dohReferenceCard() {
    var state = E('span', {}, _('Pending'));
    var entries = DOH_RESOLVERS.map(function(spec, index) {
        var entryState = E('span', {}, _('Pending'));
        var body = E('div');
        var root = E('div', { 'style': index ? 'margin-top:.9rem;' : 'margin-top:.5rem;' }, [
            E('div', { 'style': 'display:flex; flex-wrap:wrap; gap:.5rem; align-items:baseline;' }, [
                E('strong', {}, spec.name),
                E('code', {}, spec.resolver)
            ]),
            entryState,
            body
        ]);
        return {
            name: spec.name,
            resolver: spec.resolver,
            state: entryState,
            body: body,
            root: root,
            result: null
        };
    });

    return {
        root: E('div', { 'class': 'cbi-section', 'style': 'flex:1 1 22rem; min-width:0;' }, [
            E('h4', { 'style': 'margin-top:0;' }, _('Public DoH reference')),
            state
        ].concat(entries.map(function(entry) { return entry.root; }))),
        state: state,
        entries: entries
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
        var dohCard = dohReferenceCard();

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

        function requestLineRelevant(request, line) {
            if (line.toLowerCase().indexOf(request.domain.toLowerCase()) >= 0)
                return true;

            var addresses = request.seedAddresses.slice();
            if (request.trace && Array.isArray(request.trace.targets))
                addresses = addresses.concat(request.trace.targets);

            return addresses.some(function(address) { return line.indexOf(address) >= 0; });
        }

        function refreshRequestCapture(capture) {
            if (!capture || !capture.request) return Promise.resolve();

            var request = capture.request;
            request.dirty = true;
            if (request.refreshing)
                return request.refreshPromise || Promise.resolve();

            request.refreshing = true;

            function run() {
                request.dirty = false;
                var requestLines = capture.lines.slice(request.start);
                var trace = relatedTrace(requestLines, request.domain, request.seedAddresses);
                request.trace = trace;
                traceOutput.value = trace.lines.length
                    ? trace.lines.join('\n')
                    : _('Waiting for related Xray runtime log...');

                if (!trace.targets.length) {
                    requestSummary.replaceChildren();
                    return Promise.resolve();
                }

                return lookupFirewall(trace.targets, request.firewall).then(function() {
                    renderRequest(trace, request.firewall, request.dnsSources);
                });
            }

            request.refreshPromise = run().then(function repeat() {
                if (!request.dirty) return;
                return run().then(repeat);
            }).finally(function() {
                request.refreshing = false;
                request.refreshPromise = null;
            });

            return request.refreshPromise;
        }

        function appendEntry(entry) {
            if (!isRuntimeEntry(entry) || !activeCapture) return;
            var line = formatLogEntry(entry);
            activeCapture.lines.push(line);
            if (activeCapture.request && requestLineRelevant(activeCapture.request, line))
                refreshRequestCapture(activeCapture);
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
            return callDiagnosticDns(source, domain, '').then(function(result) {
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

        function refreshDns(result, card, firewall) {
            return lookupFirewall(uniqueAddresses([ result ]), firewall).then(function() {
                renderDns(result, card, firewall);
                return result;
            });
        }

        function updateDohSystemState(result) {
            var families = [];
            if (result && result.ipv4_enabled === true) families.push('IPv4');
            if (result && result.ipv6_enabled === true) families.push('IPv6');

            if (families.length)
                nftflowUi.setState(dohCard.state, 'ok', _('System: %s').format(families.join(' + ')));
            else if (result && (result.error || result.detail))
                nftflowUi.setState(dohCard.state, 'warn', result.error || result.detail);
        }

        function runDohResolver(domain, entry, firewall) {
            nftflowUi.setState(entry.state, 'notice', _('Running...'));
            entry.body.replaceChildren();

            return callDiagnosticDns('doh', domain, entry.resolver).then(function(result) {
                result = result || { ok: false, addresses: [] };
                entry.result = result;
                updateDohSystemState(result);
                nftflowUi.setState(entry.state, result.ok === true ? 'ok' : 'warn',
                    result.ok === true ? _('Done') : ((result.error || result.detail) || _('Query failed')));
                return refreshDns(result, entry, firewall);
            }).catch(function(error) {
                var result = { ok: false, addresses: [], error: nftflowUi.errorMessage(error) };
                entry.result = result;
                nftflowUi.setState(entry.state, 'error', result.error);
                return refreshDns(result, entry, firewall);
            });
        }

        function runDohReferences(domain, firewall) {
            nftflowUi.setState(dohCard.state, 'notice', _('Running...'));
            dohCard.entries.forEach(function(entry) {
                entry.result = null;
                entry.body.replaceChildren();
                nftflowUi.setState(entry.state, 'notice', _('Pending'));
            });

            var results = [];
            var chain = Promise.resolve();
            dohCard.entries.forEach(function(entry) {
                chain = chain.then(function() {
                    return runDohResolver(domain, entry, firewall);
                }).then(function(result) {
                    results.push(result);
                });
            });
            return chain.then(function() { return results; });
        }

        function renderRequest(trace, firewall, dnsSources) {
            if (!trace.targets.length) {
                requestSummary.replaceChildren(E('div', { 'class': 'notice', 'style': 'margin-top:.5rem;' }, _('No remote target IP was found in the related Xray runtime log.')));
                return;
            }

            requestSummary.replaceChildren(table([ _('Target IP'), _('Firewall set'), _('Xray route'), _('Seen in DNS') ], trace.targets.map(function(address) {
                var routes = routesForTarget(trace.lines, address);
                var dnsMatches = seenInDns(address, dnsSources);
                return E('tr', {}, [
                    E('td', {}, E('code', {}, address)),
                    E('td', {}, firewallNodes(firewall[address])),
                    E('td', {}, routes.length ? routes.map(function(route) { return E('div', {}, E('code', {}, route)); }) : '—'),
                    E('td', {}, dnsMatches.length ? dnsMatches.join(' · ') : '—')
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

                activeCapture = { lines: [], request: null };
                var dnsResults = [];
                var lanResult = null;
                var routerResult = null;
                var dohResults = [];
                var progressiveFirewall = Object.create(null);

                return runDns('lan', domain, lanCard).then(function(result) {
                    lanResult = result;
                    dnsResults.push(result);
                    return refreshDns(result, lanCard, progressiveFirewall);
                }).then(function() {
                    return runDns('router', domain, routerCard);
                }).then(function(result) {
                    routerResult = result;
                    dnsResults.push(result);
                    return refreshDns(result, routerCard, progressiveFirewall);
                }).then(function() {
                    return runDohReferences(domain, progressiveFirewall);
                }).then(function(results) {
                    dohResults = results;
                    results.forEach(function(result) { dnsResults.push(result); });

                    var dnsSources = [
                        { label: _('LAN DNS'), result: lanResult },
                        { label: _('Router DNS'), result: routerResult }
                    ];
                    dohCard.entries.forEach(function(entry, index) {
                        dnsSources.push({ label: entry.name, result: dohResults[index] });
                    });

                    activeCapture.request = {
                        start: activeCapture.lines.length,
                        domain: domain,
                        seedAddresses: uniqueAddresses(dnsResults),
                        dnsSources: dnsSources,
                        firewall: progressiveFirewall,
                        trace: { lines: [], targets: [] },
                        dirty: false,
                        refreshing: false,
                        refreshPromise: null
                    };
                    traceOutput.value = _('Waiting for related Xray runtime log...');
                    nftflowUi.setState(requestState, 'notice', _('Requesting https://%s/ ...').format(domain));
                    return callDiagnosticRequest(domain).catch(function(error) {
                        return { ok: false, detail: nftflowUi.errorMessage(error) };
                    });
                }).then(function(requestResult) {
                    nftflowUi.setState(requestState, requestResult && requestResult.ok === true ? 'ok' : 'warn',
                        requestResult && requestResult.ok === true ? _('Page request completed') : ((requestResult && requestResult.detail) || _('Page request failed')));
                    return delay(REQUEST_LOG_GRACE_MS).then(function() {
                        return refreshRequestCapture(activeCapture);
                    });
                }).then(function() {
                    var request = activeCapture.request;
                    var trace = request.trace || relatedTrace(activeCapture.lines.slice(request.start), domain, request.seedAddresses);

                    trace.targets.forEach(function(address) {
                        delete request.firewall[address];
                    });

                    return lookupFirewall(trace.targets, request.firewall).then(function(firewall) {
                        renderDns(lanResult, lanCard, firewall);
                        renderDns(routerResult, routerCard, firewall);
                        dohCard.entries.forEach(function(entry, index) {
                            renderDns(dohResults[index], entry, firewall);
                        });
                        renderRequest(trace, firewall, request.dnsSources);

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
            E('div', { 'class': 'cbi-section-descr' }, _('Compare LAN DNS, router-local DNS and public DoH references, then trace an actual HTTPS request through the live Xray runtime log and locate every related IP in the active firewall sets.')),
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
