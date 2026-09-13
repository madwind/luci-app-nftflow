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

var callPackageVersion = rpc.declare({
    object: 'luci.nftflow.package',
    method: 'version',
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

var LOG_SOURCE = /^(?:nftflow|nftflowctl)(?:\[\d+\])?:\s*/i;
var LOG_FETCH_LINES = 1000;
var LOG_LINES = LOG_FETCH_LINES;
var LOG_PENDING_MAX = LOG_FETCH_LINES;
var LOG_RECONNECT_MS = 2000;

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

function formatLogEntry(entry) {
    var message = entry && entry.msg != null ? String(entry.msg) : '';
    return message
        .replace(LOG_SOURCE, '')
        .replace(/^nftflow:\s*/i, '');
}

function runtimeLogSection(options) {
    options = options || {};
    var logState = E('span', { 'aria-live': 'polite' }, _('Loading'));
    var logFilter = E('input', {
        'class': 'cbi-input-text',
        'type': 'search',
        'placeholder': _('Regular expression'),
        'autocomplete': 'off',
        'spellcheck': 'false',
        'aria-label': _('Filter runtime log by regular expression'),
        'title': _('Enter the regular expression without /.../.')
    });
    var logOutput = E('textarea', {
        'id': 'nftflow-runtime-log', 'class': 'cbi-input-text',
        'style': 'display: block; width: 100%; min-height: 22em; box-sizing: border-box; white-space: pre-wrap; overflow-wrap: anywhere;',
        'rows': 20, 'wrap': 'soft', 'spellcheck': 'false', 'readonly': true,
        'role': 'log', 'aria-label': _('NftFlow runtime log')
    });
    var logStopped = false;
    var pageVisible = true;
    var followLogs = true;
    var logLines = [];
    var initialLogsLoaded = false;
    var historySyncInProgress = false;
    var pendingLiveEntries = [];
    var recentLogKeys = Object.create(null);
    var recentLogKeyOrder = [];
    var streamController = null;
    var reconnectTimer = null;
    var logsDeferred = true;

    function startupBusy() {
        return typeof options.isStartupBusy === 'function' && options.isStartupBusy();
    }

    function logFilterExpression() {
        var pattern = logFilter.value;
        if (!pattern) {
            logFilter.setCustomValidity('');
            logFilter.removeAttribute('aria-invalid');
            return null;
        }

        try {
            var expression = new RegExp(pattern);
            logFilter.setCustomValidity('');
            logFilter.removeAttribute('aria-invalid');
            return expression;
        } catch (error) {
            logFilter.setCustomValidity(_('Invalid regular expression.'));
            logFilter.setAttribute('aria-invalid', 'true');
            return false;
        }
    }

    function lineMatchesFilter(line, expression) {
        return expression === null || (expression !== false && expression.test(line));
    }

    function filteredLogLines() {
        var expression = logFilterExpression();
        if (expression === null)
            return logLines;
        if (expression === false)
            return [];
        return logLines.filter(function(line) {
            return lineMatchesFilter(line, expression);
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

    function appendRenderedLogLine(line) {
        var previous = logLines;
        var next = nftflowUi.boundedLines(previous.concat([ line ]), LOG_LINES);
        var retained = Math.max(0, next.length - 1);
        var dropped = previous.length - retained;
        var canAppend = dropped >= 0 && next.length > 0 && next[next.length - 1] === line;
        var expression = logFilterExpression();

        logLines = next;

        if (canAppend) {
            for (var index = 0; index < retained; index++) {
                if (previous[dropped + index] !== next[index]) {
                    canAppend = false;
                    break;
                }
            }
        }

        if (!canAppend || typeof logOutput.setRangeText !== 'function' || expression === false) {
            renderLogs();
            return;
        }

        var oldScrollTop = logOutput.scrollTop;
        var oldScrollHeight = logOutput.scrollHeight;
        var wasAtBottom = followLogs;
        var droppedVisible = [];
        var retainedVisible = 0;

        for (var i = 0; i < previous.length; i++) {
            if (!lineMatchesFilter(previous[i], expression))
                continue;
            if (i < dropped)
                droppedVisible.push(previous[i]);
            else
                retainedVisible++;
        }

        if (droppedVisible.length) {
            var removeChars = droppedVisible.join('\n').length + (retainedVisible ? 1 : 0);
            logOutput.setRangeText('', 0, removeChars, 'preserve');
        }

        var removedHeight = Math.max(0, oldScrollHeight - logOutput.scrollHeight);
        if (lineMatchesFilter(line, expression)) {
            var appendText = (logOutput.value ? '\n' : '') + line;
            logOutput.setRangeText(appendText, logOutput.value.length, logOutput.value.length, 'preserve');
        }

        if (wasAtBottom)
            logOutput.scrollTop = logOutput.scrollHeight;
        else
            logOutput.scrollTop = Math.max(0, oldScrollTop - removedHeight);
    }

    function isRelevantLogEntry(entry) {
        var message = entry && entry.msg != null ? String(entry.msg) : '';
        return LOG_SOURCE.test(message);
    }

    function logEntryKey(entry) {
        return String(entry && entry.time != null ? entry.time : '') + '\n' +
            String(entry && entry.priority != null ? entry.priority : '') + '\n' +
            String(entry && entry.msg != null ? entry.msg : '');
    }

    function rememberLogEntry(entry) {
        var key = logEntryKey(entry);
        if (recentLogKeys[key])
            return false;

        recentLogKeys[key] = true;
        recentLogKeyOrder.push(key);
        while (recentLogKeyOrder.length > LOG_FETCH_LINES * 2)
            delete recentLogKeys[recentLogKeyOrder.shift()];
        return true;
    }

    function queuePendingLogEntry(entry) {
        pendingLiveEntries.push(entry);
        if (pendingLiveEntries.length > LOG_PENDING_MAX)
            pendingLiveEntries.splice(0, pendingLiveEntries.length - LOG_PENDING_MAX);
    }

    function appendKnownLogEntry(entry) {
        if (!isRelevantLogEntry(entry) || !rememberLogEntry(entry))
            return;
        appendRenderedLogLine(formatLogEntry(entry));
    }

    function appendLogEntry(entry) {
        if (!isRelevantLogEntry(entry))
            return;
        if (!initialLogsLoaded || historySyncInProgress) {
            queuePendingLogEntry(entry);
            return;
        }
        appendKnownLogEntry(entry);
    }

    function mergeLogHistory(entries) {
        var combined = (Array.isArray(entries) ? entries : []).concat(pendingLiveEntries);
        pendingLiveEntries = [];
        historySyncInProgress = false;

        if (!initialLogsLoaded) {
            var merged = [];
            combined.forEach(function(entry) {
                if (!isRelevantLogEntry(entry) || !rememberLogEntry(entry))
                    return;
                merged.push(formatLogEntry(entry));
            });
            initialLogsLoaded = true;
            logLines = nftflowUi.boundedLines(merged, LOG_LINES);
            renderLogs();
            return;
        }

        combined.forEach(appendKnownLogEntry);
    }

    function syncRecentLogs() {
        if (!pageVisible || logStopped)
            return Promise.resolve(false);
        if (startupBusy()) {
            deferLogs();
            return Promise.resolve(false);
        }
        if (historySyncInProgress)
            return Promise.resolve(false);

        historySyncInProgress = true;
        return callLogRead(LOG_FETCH_LINES, false, true).then(function(entries) {
            mergeLogHistory(entries);
            return true;
        }).catch(function(error) {
            console.warn(error);
            mergeLogHistory([]);
            return false;
        });
    }

    function consumeSseFrame(frame) {
        var eventName = 'message';
        var data = [];
        frame.split('\n').forEach(function(line) {
            if (!line || line.charAt(0) === ':') return;
            if (line.indexOf('event:') === 0) eventName = line.slice(6).trim();
            else if (line.indexOf('data:') === 0) data.push(line.slice(5).trimStart());
        });
        if (eventName !== 'message' || !data.length) return;
        try { appendLogEntry(JSON.parse(data.join('\n'))); } catch (error) { console.warn(error); }
    }

    function pump(reader, decoder, controller, state) {
        return reader.read().then(function(chunk) {
            if (chunk.done) throw new Error('log subscription ended');
            state.buffer += decoder.decode(chunk.value, { stream: true }).replace(/\r\n/g, '\n');
            var boundary;
            while ((boundary = state.buffer.indexOf('\n\n')) >= 0) {
                consumeSseFrame(state.buffer.slice(0, boundary));
                state.buffer = state.buffer.slice(boundary + 2);
            }
            if (!controller.signal.aborted) return pump(reader, decoder, controller, state);
        });
    }

    function clearReconnect() {
        if (reconnectTimer !== null) {
            window.clearTimeout(reconnectTimer);
            reconnectTimer = null;
        }
    }

    function stopLogStream() {
        clearReconnect();
        if (streamController) streamController.abort();
        streamController = null;
    }

    function deferLogs() {
        clearReconnect();
        logsDeferred = true;
        if (!streamController && !logStopped)
            nftflowUi.setState(logState, 'notice', _('Waiting for service...'));
    }

    function scheduleReconnect() {
        if (logStopped || !pageVisible || reconnectTimer !== null) return;
        if (startupBusy()) {
            deferLogs();
            return;
        }
        nftflowUi.setState(logState, 'notice', _('Reconnecting'));
        reconnectTimer = window.setTimeout(function() {
            reconnectTimer = null;
            startLogStream(true);
        }, LOG_RECONNECT_MS);
    }

    function startLogStream(backfill) {
        if (logStopped || !pageVisible || streamController) return Promise.resolve();
        if (startupBusy()) {
            deferLogs();
            return Promise.resolve();
        }
        if (typeof fetch !== 'function' || typeof TextDecoder !== 'function' || typeof AbortController !== 'function') {
            nftflowUi.setState(logState, 'warn', _('Unavailable'));
            return Promise.resolve();
        }

        clearReconnect();
        logsDeferred = false;
        nftflowUi.setState(logState, 'notice', _('Connecting'));
        var controller = new AbortController();
        streamController = controller;

        return fetch('/ubus/subscribe/log', {
            method: 'GET',
            headers: { 'Accept': 'text/event-stream', 'Authorization': 'Bearer ' + rpc.getSessionID() },
            credentials: 'same-origin', cache: 'no-store', signal: controller.signal
        }).then(function(response) {
            if (!response.ok || !response.body) throw new Error('log subscription HTTP ' + response.status);
            nftflowUi.setState(logState, 'ok', _('Live'));
            if (backfill || !initialLogsLoaded)
                syncRecentLogs();
            return pump(response.body.getReader(), new TextDecoder(), controller, { buffer: '' });
        }).catch(function(error) {
            if (!controller.signal.aborted) {
                console.warn(error);
                if (!initialLogsLoaded && !startupBusy())
                    syncRecentLogs();
            }
        }).then(function() {
            if (streamController === controller) streamController = null;
            if (!controller.signal.aborted) scheduleReconnect();
        });
    }

    function resumeLogs() {
        if (logStopped || !pageVisible)
            return;
        if (startupBusy()) {
            deferLogs();
            return;
        }
        logsDeferred = false;
        if (!streamController)
            startLogStream(true);
        else if (!initialLogsLoaded)
            syncRecentLogs();
    }

    function lifecycleChanged() {
        if (startupBusy()) {
            if (!streamController && !logStopped)
                deferLogs();
            return;
        }
        if (logsDeferred)
            resumeLogs();
    }

    logOutput.addEventListener('scroll', function() {
        followLogs = logOutput.scrollHeight - logOutput.scrollTop - logOutput.clientHeight <= 4;
    });
    logFilter.addEventListener('input', renderLogs);

    var logStreamButton = E('button', { 'class': 'btn cbi-button cbi-button-action', 'type': 'button' }, _('Stop'));
    logStreamButton.addEventListener('click', ui.createHandlerFn(logStreamButton, function() {
        logStopped = !logStopped;
        logStreamButton.textContent = logStopped ? _('Start') : _('Stop');
        if (logStopped) {
            stopLogStream();
            nftflowUi.setState(logState, 'notice', _('Stopped'));
            return Promise.resolve();
        }
        resumeLogs();
        return Promise.resolve();
    }));

    window.addEventListener('pagehide', function() {
        pageVisible = false;
        stopLogStream();
    }, { once: true });

    var root = E('div', { 'class': 'cbi-section' }, [
        E('h3', { 'class': 'cbi-section-title' }, _('Runtime log')),
        E('div', { 'class': 'cbi-section-descr', 'style': 'display: flex; flex-wrap: wrap; align-items: center; gap: .5rem;' }, [
            logState,
            E('div', { 'style': 'display: inline-flex; flex-wrap: wrap; align-items: center; gap: .5rem; margin-left: auto;' }, [
                E('label', { 'style': 'display: inline-flex; align-items: center; gap: .5rem;' }, [ _('Filter'), logFilter ]),
                logStreamButton
            ])
        ]),
        logOutput
    ]);

    window.setTimeout(function() {
        if (!pageVisible)
            return;
        lifecycleChanged();
    }, 0);

    return {
        root: root,
        lifecycleChanged: lifecycleChanged
    };
}

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    load: function() {
        return Promise.all([
            L.resolveDefault(callStatus(), { ok: false, error: _('Unable to read service status.') }),
            L.resolveDefault(callTraffic(), { ok: true, available: false, inbounds: [], outbounds: [] }),
            L.resolveDefault(callPackageVersion(), { ok: false })
        ]);
    },

    render: function(data) {
        document.title = _('NftFlow | Overview');

        var service = E('span', { 'aria-live': 'polite' });
        var uptime = E('span');
        var firewall = E('span', { 'aria-live': 'polite' });
        var routing = E('span', { 'aria-live': 'polite' });
        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var inboundTable = trafficTable();
        var outboundTable = trafficTable();
        var inboundSection = trafficSection(_('Inbounds'), inboundTable);
        var outboundSection = trafficSection(_('Outbounds'), outboundTable);
        var serviceButtons = [];
        var actionInProgress = false;
        var activeAction = null;
        var lastStatus = null;
        var previousTraffic = null;
        var pageVisible = true;
        var runtimeLogController = null;

        inboundSection.hidden = true;
        outboundSection.hidden = true;

        function setMessage(state, value) {
            nftflowUi.setState(message, state, value);
        }

        function startupBusy() {
            return actionInProgress && (activeAction === 'start' || activeAction === 'restart');
        }

        function notifyLogLifecycle() {
            if (runtimeLogController)
                runtimeLogController.lifecycleChanged();
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
            notifyLogLifecycle();
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
            activeAction = action;
            setMessage('notice', _('%s requested...').format(actionText(action)));
            updateActionButtons();
            notifyLogLifecycle();

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
                activeAction = null;
                updateActionButtons();
                refreshTraffic();
                notifyLogLifecycle();
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

        var packageVersion = data && data[2];
        var version = packageVersion && packageVersion.ok === true && packageVersion.version
            ? packageVersion.version : '—';

        var initialStatus = data && data[0];
        if (initialStatus && initialStatus.ok === true)
            updateStatus(initialStatus);
        else
            setMessage('error', nftflowUi.errorMessage(initialStatus, _('Unable to read service status.')));

        if (lastStatus && lastStatus.running === true)
            updateTraffic(data && data[1]);
        else
            hideTraffic();

        poll.add(refreshStatus, L.env.pollinterval);
        poll.add(refreshTraffic, L.env.pollinterval);
        window.addEventListener('pagehide', function() {
            pageVisible = false;
            poll.remove(refreshStatus);
            poll.remove(refreshTraffic);
        }, { once: true });

        runtimeLogController = runtimeLogSection({ isStartupBusy: startupBusy });

        var root = E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Overview')),
            E('div', { 'class': 'cbi-map-descr' }, [
                _('Managed process state, traffic statistics and NftFlow traffic-rule lifecycle.'),
                ' · ', _('Version'), ': ', E('strong', {}, version)
            ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Runtime')),
                E('table', { 'class': 'table cbi-section-table' }, [
                    E('tbody', {}, [
                        tableRow(_('Service'), service),
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
            runtimeLogController.root
        ]);

        updateActionButtons();
        return root;
    }
});