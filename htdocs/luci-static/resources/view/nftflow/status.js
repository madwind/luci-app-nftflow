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
    expect: { log: [] },
    reject: true
});

var LOG_TAG = 'nftflowctl';
var LOG_LINES = 300;
var LOG_MAX_BYTES = 96 * 1024;
var LOG_POLL_INTERVAL = 1;
var ACTION_TIMEOUT = 45000;

function numberOrNull(value) {
    var number = Number(value);
    return isFinite(number) && number >= 0 ? number : null;
}

function tableRow(label, value) {
    return E('tr', { 'class': 'tr' }, [
        E('th', { 'class': 'th cbi-section-table-cell' }, label),
        E('td', { 'class': 'td cbi-section-table-cell' }, value)
    ]);
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

function actionText(action) {
    if (action === 'start')
        return _('Start');
    if (action === 'stop')
        return _('Stop');
    if (action === 'restart')
        return _('Restart');
    return _('Service action');
}

function validateLogResponse(entries) {
    if (!Array.isArray(entries))
        throw new Error(_('Runtime log returned an invalid line list.'));

    return entries.filter(function(entry) {
        var message = entry && entry.msg != null ? String(entry.msg) : '';
        return message.toLowerCase().indexOf(LOG_TAG) !== -1;
    }).map(function(entry) {
        return String(entry.msg || '');
    });
}

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    load: function() {
        return Promise.all([
            L.resolveDefault(callStatus(), { ok: false, error: _('Unable to read service status.') }),
            L.resolveDefault(callLogRead(LOG_LINES, false, true), [])
        ]);
    },

    render: function(data) {
        document.title = _('NftFlow | Overview');

        var service = E('span', { 'aria-live': 'polite' });
        var uptime = E('span');
        var firewall = E('span', { 'aria-live': 'polite' });
        var routing = E('span', { 'aria-live': 'polite' });
        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var logState = E('span', { 'aria-live': 'polite' }, _('Connecting'));
        var logFilter = E('input', {
            'class': 'cbi-input-text',
            'type': 'search',
            'placeholder': _('Filter'),
            'autocomplete': 'off',
            'spellcheck': 'false',
            'aria-label': _('Filter runtime log')
        });
        var logOutput = E('textarea', {
            'id': 'nftflow-runtime-log',
            'class': 'cbi-input-text',
            'style': 'display: block; width: 100%; min-height: 22em; box-sizing: border-box;',
            'rows': 20,
            'wrap': 'off',
            'spellcheck': 'false',
            'readonly': true,
            'role': 'log',
            'aria-label': _('NftFlow runtime log')
        });
        var serviceButtons = [];
        var statusRequest = null;
        var logRequest = null;
        var actionInProgress = false;
        var actionDeadline = 0;
        var lastStatus = null;
        var paused = false;
        var pageVisible = true;
        var followLogs = true;
        var logLines = [];

        function setMessage(state, value) {
            nftflowUi.setState(message, state, value);
        }

        function updateActionButtons() {
            var running = lastStatus && typeof lastStatus.running === 'boolean' ? lastStatus.running : null;

            serviceButtons.forEach(function(button) {
                button.node.disabled = actionInProgress || running === null ||
                    (button.name === 'start' && running === true) ||
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
            var firewallKnown = typeof result.firewall_active === 'boolean';
            var routingKnown = typeof result.route_active === 'boolean';

            nftflowUi.setState(service, running ? 'ok' : runningKnown ? 'warn' : 'notice',
                runningKnown
                    ? running
                        ? (pid === null ? _('Running') : _('Running · PID %s').format(pid))
                        : _('Stopped')
                    : _('Unavailable'));
            nftflowUi.setText(uptime, running ? formatUptime(result.uptime) : '—');
            nftflowUi.setState(firewall,
                firewallKnown && result.firewall_active === true ? 'ok' : firewallKnown ? 'warn' : 'notice',
                firewallKnown ? (result.firewall_active === true ? _('Active') : _('Inactive')) : _('Unavailable'));

            if (!routingKnown) {
                nftflowUi.setState(routing, 'notice', _('Unavailable'));
            } else if (result.route_active === true) {
                nftflowUi.setState(routing, 'ok', result.route_ipv6 === true
                    ? _('Active · IPv4 + IPv6')
                    : _('Active · IPv4'));
            } else {
                nftflowUi.setState(routing, 'warn', _('Inactive'));
            }

            if (!actionInProgress && result.runtime_state === 'failed' && result.state_error)
                setMessage('error', result.state_error);

            updateActionButtons();
            return result;
        }

        function showStatusUnavailable(error) {
            if (!lastStatus) {
                nftflowUi.setState(service, 'notice', _('Unavailable'));
                nftflowUi.setText(uptime, '—');
                nftflowUi.setState(firewall, 'notice', _('Unavailable'));
                nftflowUi.setState(routing, 'notice', _('Unavailable'));
            }
            if (error && !actionInProgress)
                console.warn(error);
            updateActionButtons();
        }

        function refreshStatus() {
            if (!pageVisible || statusRequest)
                return statusRequest || Promise.resolve();

            statusRequest = callStatus().then(function(result) {
                return updateStatus(result);
            }).catch(function(error) {
                showStatusUnavailable(error);
                return null;
            }).then(function(result) {
                statusRequest = null;
                return result;
            });

            return statusRequest;
        }

        function filteredLogLines() {
            var filter = logFilter.value.trim().toLowerCase();
            if (!filter)
                return logLines;

            return logLines.filter(function(line) {
                return line.toLowerCase().indexOf(filter) !== -1;
            });
        }

        function renderLogs() {
            var oldScrollTop = logOutput.scrollTop;
            var wasAtBottom = followLogs;

            logOutput.value = filteredLogLines().join('\n');
            if (wasAtBottom)
                logOutput.scrollTop = logOutput.scrollHeight;
            else
                logOutput.scrollTop = oldScrollTop;
        }

        function applyLogResponse(entries) {
            logLines = nftflowUi.boundedLines(validateLogResponse(entries), LOG_LINES, LOG_MAX_BYTES);
            renderLogs();
            nftflowUi.setState(logState, paused ? 'notice' : 'ok', paused ? _('Paused') : _('Live'));
            return entries;
        }

        function requestLogs() {
            if (paused || !pageVisible || logRequest)
                return logRequest || Promise.resolve();

            logRequest = callLogRead(LOG_LINES, false, true).then(function(entries) {
                return applyLogResponse(entries);
            }).catch(function(error) {
                if (pageVisible) {
                    nftflowUi.setState(logState, 'warn', _('Unavailable'));
                    console.warn(error);
                }
                return null;
            }).then(function(result) {
                logRequest = null;
                return result;
            });

            return logRequest;
        }

        function waitForLifecycle(action) {
            return callStatus().then(function(result) {
                updateStatus(result);

                if (result.runtime_state === 'failed')
                    throw new Error(result.state_error || _('NftFlow failed to reach the requested state.'));

                var complete = action === 'stop'
                    ? result.running !== true && result.runtime_state === 'stopped'
                    : result.running === true && result.runtime_state === 'ready';

                if (complete)
                    return result;
                if (Date.now() >= actionDeadline)
                    throw new Error(_('NftFlow did not reach the requested state within 45 seconds.'));

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
            actionDeadline = Date.now() + ACTION_TIMEOUT;
            setMessage('notice', _('%s requested...').format(actionText(action)));
            updateActionButtons();

            return callAction(action).then(function(result) {
                return nftflowUi.requireOk(result, _('Service action failed.'));
            }).then(function() {
                return waitForLifecycle(action);
            }).then(function(result) {
                setMessage('ok', _('NftFlow %s completed.').format(actionText(action)));
                return result;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Service action failed.')));
                return false;
            }).then(function(result) {
                actionInProgress = false;
                updateActionButtons();
                requestLogs();
                return result;
            });
        }

        function serviceButton(name, title, className) {
            var button = E('button', {
                'class': 'btn cbi-button ' + className,
                'type': 'button'
            }, title);

            serviceButtons.push({ name: name, node: button });
            button.addEventListener('click', ui.createHandlerFn(button, function() {
                return serviceAction(name);
            }));
            return button;
        }

        logOutput.addEventListener('scroll', function() {
            followLogs = logOutput.scrollHeight - logOutput.scrollTop - logOutput.clientHeight <= 4;
        });
        logFilter.addEventListener('input', renderLogs);

        var pauseButton = E('button', {
            'class': 'btn cbi-button cbi-button-action',
            'type': 'button'
        }, _('Pause'));
        pauseButton.addEventListener('click', ui.createHandlerFn(pauseButton, function() {
            paused = !paused;
            pauseButton.textContent = paused ? _('Resume') : _('Pause');
            nftflowUi.setState(logState, paused ? 'notice' : 'ok', paused ? _('Paused') : _('Live'));
            return paused ? Promise.resolve() : requestLogs();
        }));

        var initialStatus = data && data[0];
        var initialLogs = data && data[1];

        if (initialStatus && initialStatus.ok === true)
            updateStatus(initialStatus);
        else
            showStatusUnavailable(initialStatus && initialStatus.error);

        try {
            applyLogResponse(initialLogs);
        } catch (error) {
            nftflowUi.setState(logState, 'warn', _('Unavailable'));
            console.warn(error);
        }

        poll.add(refreshStatus, L.env.pollinterval);
        poll.add(requestLogs, LOG_POLL_INTERVAL);
        window.addEventListener('pagehide', function() {
            pageVisible = false;
            poll.remove(refreshStatus);
            poll.remove(requestLogs);
        }, { once: true });

        var root = E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Overview')),
            E('div', { 'class': 'cbi-map-descr' }, _('Xray process, runtime integration and live log.')),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Runtime')),
                E('table', { 'class': 'table cbi-section-table' }, [
                    E('tbody', {}, [
                        tableRow(_('Xray'), service),
                        tableRow(_('Uptime'), uptime),
                        tableRow(_('Firewall'), firewall),
                        tableRow(_('Routing'), routing)
                    ])
                ]),
                E('div', { 'class': 'cbi-page-actions' }, [
                    serviceButton('start', _('Start'), 'cbi-button-positive'),
                    serviceButton('stop', _('Stop'), 'cbi-button-negative'),
                    serviceButton('restart', _('Restart'), 'cbi-button-positive')
                ]),
                message
            ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Runtime log')),
                E('div', {
                    'class': 'cbi-section-descr',
                    'style': 'display: flex; flex-wrap: wrap; align-items: center; gap: .5rem;'
                }, [
                    logState,
                    E('div', {
                        'style': 'display: inline-flex; flex-wrap: wrap; align-items: center; gap: .5rem; margin-left: auto;'
                    }, [
                        E('label', {
                            'style': 'display: inline-flex; align-items: center; gap: .5rem;'
                        }, [ _('Filter'), logFilter ]),
                        pauseButton
                    ])
                ]),
                logOutput
            ])
        ]);

        updateActionButtons();
        return root;
    }
});
