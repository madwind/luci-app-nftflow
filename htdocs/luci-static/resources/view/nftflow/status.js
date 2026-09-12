'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require nftflow.ui as nftflowUi';

var callStatus = rpc.declare({
    object: 'luci.nftflow',
    method: 'status',
    expect: { '': {} },
    reject: true
});

var callServiceRuntime = rpc.declare({
    object: 'luci.nftflow',
    method: 'service_runtime',
    expect: { '': {} },
    reject: true
});

var callTraffic = rpc.declare({
    object: 'luci.nftflow.metrics',
    method: 'traffic',
    expect: { '': {} },
    reject: true
});

var callAction = rpc.declare({
    object: 'luci.nftflow',
    method: 'action',
    params: [ 'name' ],
    expect: { '': {} },
    reject: true
});

var callLogRead = rpc.declare({
    object: 'log',
    method: 'read',
    params: [ 'lines', 'stream', 'oneshot' ],
    expect: { log: [] }
});

var LOG_LINES = 400;

function numberOrNull(value) {
    var number = Number(value);
    return isFinite(number) && number >= 0 ? number : null;
}

function formatUptime(value) {
    var seconds = numberOrNull(value);
    if (seconds === null)
        return '—';
    seconds = Math.floor(seconds);
    var days = Math.floor(seconds / 86400);
    var hours = Math.floor(seconds % 86400 / 3600);
    var minutes = Math.floor(seconds % 3600 / 60);
    if (days > 0)
        return _('%sd %sh %sm').format(days, hours, minutes);
    if (hours > 0)
        return _('%sh %sm').format(hours, minutes);
    if (minutes > 0)
        return _('%sm').format(minutes);
    return _('%ss').format(seconds);
}

function formatRate(value) {
    var bytesPerSecond = numberOrNull(value);
    return bytesPerSecond === null ? '—' : '%s/s'.format(nftflowUi.formatBytes(bytesPerSecond));
}

function tableRow(label, value) {
    return E('tr', { 'class': 'tr' }, [
        E('th', { 'class': 'th cbi-section-table-cell' }, label),
        E('td', { 'class': 'td cbi-section-table-cell' }, value)
    ]);
}

function trafficTable() {
    return E('table', { 'class': 'table' }, [
        E('tr', { 'class': 'tr table-titles' }, [
            E('th', { 'class': 'th' }, _('Tag')),
            E('th', { 'class': 'th' }, _('Upload')),
            E('th', { 'class': 'th' }, _('Download')),
            E('th', { 'class': 'th' }, _('Uploaded')),
            E('th', { 'class': 'th' }, _('Downloaded'))
        ])
    ]);
}

function trafficSection(title, table) {
    return E('div', { 'class': 'cbi-section' }, [
        E('h3', { 'class': 'cbi-section-title' }, title),
        table
    ]);
}

function actionText(action) {
    if (action === 'start')
        return _('Start');
    if (action === 'stop')
        return _('Stop');
    if (action === 'restart')
        return _('Restart');
    return _('Service action');
}

function isRelevantLogEntry(entry) {
    var message = entry && entry.msg != null ? String(entry.msg).toLowerCase() : '';
    return message.indexOf('nftflowctl') !== -1 || message.indexOf('nftflow') !== -1;
}

function formatLogEntry(entry) {
    var message = entry && entry.msg != null ? String(entry.msg) : '';
    return message.replace(/^nftflowctl(?:\[\d+\])?:\s*/, '');
}

function renderLogEntries(entries) {
    var lines = [];
    (Array.isArray(entries) ? entries : []).forEach(function(entry) {
        if (!isRelevantLogEntry(entry))
            return;
        var message = formatLogEntry(entry);
        if (message)
            lines.push(message);
    });
    return lines.join('\n') + (lines.length ? '\n' : '');
}

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    load: function() {
        return Promise.all([
            L.resolveDefault(callStatus(), { ok: false, error: _('Unable to read service status.') }),
            L.resolveDefault(callTraffic(), { ok: true, available: false, inbounds: [], outbounds: [] }),
            L.resolveDefault(callLogRead(LOG_LINES, false, true), [])
        ]);
    },

    render: function(data) {
        document.title = _('NftFlow | Overview');

        var service = E('span', { 'aria-live': 'polite' });
        var command = E('code');
        var uptime = E('span');
        var firewall = E('span', { 'aria-live': 'polite' });
        var routing = E('span', { 'aria-live': 'polite' });
        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var inboundTable = trafficTable();
        var outboundTable = trafficTable();
        var inboundSection = trafficSection(_('Inbounds'), inboundTable);
        var outboundSection = trafficSection(_('Outbounds'), outboundTable);
        var logOutput = E('textarea', {
            'class': 'cbi-input-text',
            'style': 'display:block;width:100%;min-height:22em;box-sizing:border-box;white-space:pre-wrap;overflow-wrap:anywhere;',
            'rows': 20,
            'wrap': 'soft',
            'spellcheck': 'false',
            'readonly': true,
            'role': 'log',
            'aria-label': _('NftFlow runtime log')
        });
        var serviceButtons = [];
        var actionInProgress = false;
        var lastStatus = null;
        var previousTraffic = null;
        var pageVisible = true;

        inboundSection.hidden = true;
        outboundSection.hidden = true;

        function setMessage(state, value) {
            nftflowUi.setState(message, state, value);
        }

        function updateActionButtons() {
            var running = lastStatus && typeof lastStatus.running === 'boolean' ? lastStatus.running : null;
            serviceButtons.forEach(function(button) {
                if (button.primary) {
                    button.name = running === true ? 'restart' : 'start';
                    button.node.textContent = running === true ? _('Restart') : _('Start');
                }
                button.node.disabled = actionInProgress || running === null ||
                    (button.name === 'stop' && running === false);
            });
        }

        function updateStatus(result) {
            if (!result || result.ok !== true)
                throw new Error(nftflowUi.errorMessage(result, _('Service status is unavailable.')));

            lastStatus = result;
            var runningKnown = typeof result.running === 'boolean';
            var running = runningKnown && result.running === true;
            var pid = numberOrNull(result.pid);

            nftflowUi.setState(service, running ? 'ok' : runningKnown ? 'warn' : 'notice',
                runningKnown
                    ? running
                        ? (pid === null ? _('Running') : _('Running · PID %s').format(pid))
                        : _('Stopped')
                    : _('Unavailable'));
            nftflowUi.setText(command, result.runtime_command || '—');
            nftflowUi.setText(uptime, running ? formatUptime(result.uptime) : '—');
            nftflowUi.setState(firewall, result.firewall_active === true ? 'ok' : 'warn', result.firewall_active === true ? _('Active') : _('Inactive'));
            nftflowUi.setState(routing, result.route_active === true ? 'ok' : 'warn', result.route_active === true
                ? (result.route_ipv6 === true ? _('Active · IPv4 + IPv6') : _('Active · IPv4'))
                : _('Inactive'));

            if (!running) {
                previousTraffic = null;
                hideTraffic();
            }
            if (result.runtime_error)
                setMessage('error', result.runtime_error);
            updateActionButtons();
            return result;
        }

        function refreshStatus() {
            if (!pageVisible || actionInProgress)
                return Promise.resolve();
            return callStatus().then(updateStatus).catch(function(error) {
                console.warn(error);
            });
        }

        function trafficKey(kind, tag) {
            return kind + '\n' + tag;
        }

        function sortableTrafficValue(value, display) {
            var number = numberOrNull(value);
            return E('span', { 'data-value': number === null ? '' : String(Math.round(number)) }, display);
        }

        function renderTrafficRows(table, rows, kind, now) {
            var rendered = [];
            var previous = previousTraffic && previousTraffic.rows || Object.create(null);
            var elapsed = previousTraffic ? Math.max(0, (now - previousTraffic.time) / 1000) : 0;

            (Array.isArray(rows) ? rows : []).slice().sort(function(a, b) {
                return String(a.tag || '').localeCompare(String(b.tag || ''));
            }).forEach(function(row) {
                var tag = String(row && row.tag != null ? row.tag : '');
                var uplink = numberOrNull(row && row.uplink);
                var downlink = numberOrNull(row && row.downlink);
                var old = previous[trafficKey(kind, tag)];
                var uploadRate = old && elapsed > 0 && uplink !== null && uplink >= old.uplink
                    ? (uplink - old.uplink) / elapsed : null;
                var downloadRate = old && elapsed > 0 && downlink !== null && downlink >= old.downlink
                    ? (downlink - old.downlink) / elapsed : null;

                rendered.push([
                    tag || '—',
                    sortableTrafficValue(uploadRate, formatRate(uploadRate)),
                    sortableTrafficValue(downloadRate, formatRate(downloadRate)),
                    sortableTrafficValue(uplink, uplink === null ? '—' : nftflowUi.formatBytes(uplink)),
                    sortableTrafficValue(downlink, downlink === null ? '—' : nftflowUi.formatBytes(downlink))
                ]);
            });

            cbi_update_table(table, rendered);
        }

        function hideTraffic() {
            inboundSection.hidden = true;
            outboundSection.hidden = true;
            previousTraffic = null;
        }

        function updateTraffic(result) {
            if (!result || result.ok !== true || result.available !== true) {
                hideTraffic();
                return result;
            }

            var inbounds = Array.isArray(result.inbounds) ? result.inbounds : [];
            var outbounds = Array.isArray(result.outbounds) ? result.outbounds : [];
            if (!inbounds.length || !outbounds.length) {
                hideTraffic();
                return result;
            }

            var now = Date.now();
            inboundSection.hidden = false;
            outboundSection.hidden = false;
            renderTrafficRows(inboundTable, inbounds, 'inbound', now);
            renderTrafficRows(outboundTable, outbounds, 'outbound', now);

            var snapshot = Object.create(null);
            [ [ 'inbound', inbounds ], [ 'outbound', outbounds ] ].forEach(function(group) {
                group[1].forEach(function(row) {
                    var uplink = numberOrNull(row && row.uplink);
                    var downlink = numberOrNull(row && row.downlink);
                    if (uplink !== null && downlink !== null)
                        snapshot[trafficKey(group[0], String(row.tag || ''))] = { uplink: uplink, downlink: downlink };
                });
            });
            previousTraffic = { time: now, rows: snapshot };
            return result;
        }

        function refreshTraffic() {
            if (!pageVisible || !lastStatus || lastStatus.running !== true) {
                hideTraffic();
                return Promise.resolve();
            }
            return callTraffic().then(updateTraffic).catch(function(error) {
                hideTraffic();
                console.warn(error);
            });
        }

        function refreshLogs() {
            if (!pageVisible)
                return Promise.resolve();
            return callLogRead(LOG_LINES, false, true).then(function(entries) {
                var next = renderLogEntries(entries);
                if (logOutput.value !== next) {
                    var follow = logOutput.scrollHeight - logOutput.scrollTop - logOutput.clientHeight <= 4;
                    logOutput.value = next;
                    if (follow)
                        logOutput.scrollTop = logOutput.scrollHeight;
                }
            }).catch(function(error) {
                console.warn(error);
            });
        }

        function waitForLifecycle(action) {
            if (!pageVisible)
                return Promise.resolve(false);
            return callServiceRuntime().then(function(state) {
                state = state || {};
                if (state.ok === false)
                    throw new Error(state.error || _('Unable to read NftFlow startup state.'));
                if (state.state === 'failed')
                    return callStatus().then(updateStatus);

                var complete = action === 'stop'
                    ? state.running !== true && state.state === 'stopped'
                    : state.ready === true;
                if (complete)
                    return callStatus().then(updateStatus);

                setMessage('notice', action === 'stop' ? _('Stopping NftFlow...') : _('Starting NftFlow...'));
                return new Promise(function(resolve) {
                    window.setTimeout(resolve, 1000);
                }).then(function() {
                    return waitForLifecycle(action);
                });
            });
        }

        function serviceAction(action) {
            actionInProgress = true;
            setMessage('notice', _('%s requested...').format(actionText(action)));
            updateActionButtons();

            return callAction(action).then(function(result) {
                return nftflowUi.requireOk(result, _('Service action failed.'));
            }).then(function() {
                return waitForLifecycle(action);
            }).then(function(result) {
                if (result && result.runtime_state === 'failed')
                    return false;
                setMessage('ok', _('NftFlow %s completed.').format(actionText(action)));
                return result;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Service action failed.')));
                return false;
            }).then(function(result) {
                actionInProgress = false;
                updateActionButtons();
                refreshTraffic();
                refreshLogs();
                return result;
            });
        }

        function serviceButton(name, title, className, primary) {
            var button = E('button', {
                'class': 'btn cbi-button ' + className,
                'type': 'button'
            }, title);
            var entry = { name: name, node: button, primary: primary === true };
            serviceButtons.push(entry);
            button.addEventListener('click', ui.createHandlerFn(button, function() {
                return serviceAction(entry.name);
            }));
            return button;
        }

        var initialStatus = data && data[0];
        if (initialStatus && initialStatus.ok === true)
            updateStatus(initialStatus);
        else
            setMessage('error', nftflowUi.errorMessage(initialStatus, _('Unable to read service status.')));

        if (lastStatus && lastStatus.running === true)
            updateTraffic(data && data[1]);
        else
            hideTraffic();
        logOutput.value = renderLogEntries(data && data[2]);

        poll.add(refreshStatus, L.env.pollinterval);
        poll.add(refreshTraffic, L.env.pollinterval);
        poll.add(refreshLogs, L.env.pollinterval);
        window.addEventListener('pagehide', function() {
            pageVisible = false;
            poll.remove(refreshStatus);
            poll.remove(refreshTraffic);
            poll.remove(refreshLogs);
        }, { once: true });

        var root = E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Overview')),
            E('div', { 'class': 'cbi-map-descr' }, _('Managed process state, traffic statistics and NftFlow traffic-rule lifecycle.')),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Runtime')),
                E('table', { 'class': 'table cbi-section-table' }, [
                    E('tbody', {}, [
                        tableRow(_('Service'), service),
                        tableRow(_('Executable'), command),
                        tableRow(_('Uptime'), uptime),
                        tableRow(_('Firewall'), firewall),
                        tableRow(_('Routing'), routing)
                    ])
                ]),
                E('div', { 'class': 'cbi-page-actions' }, [
                    serviceButton('start', _('Start'), 'cbi-button-positive', true),
                    serviceButton('stop', _('Stop'), 'cbi-button-negative')
                ]),
                message
            ]),
            inboundSection,
            outboundSection,
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Runtime log')),
                logOutput
            ])
        ]);

        updateActionButtons();
        return root;
    }
});
