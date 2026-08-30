'use strict';
'require view';
'require poll';
'require rpc';
'require ui';
'require nftflow.ui as nftflowUi';

var callStatus = rpc.declare({
    object: 'luci.nftflow',
    method: 'geo_status',
    expect: { '': {} },
    reject: true
});

var callCheck = rpc.declare({
    object: 'luci.nftflow',
    method: 'geo_check',
    params: [ 'kind' ],
    expect: { '': {} },
    reject: true
});

var callUpdate = rpc.declare({
    object: 'luci.nftflow',
    method: 'geo_update',
    params: [ 'kind' ],
    expect: { '': {} },
    reject: true
});

var GEO_KINDS = [ 'geoip', 'geosite' ];

function assetLabel(kind) {
    return kind === 'geoip' ? _('GeoIP') : _('GeoSite');
}

function assetVersion(asset) {
    var update = asset && asset.update;
    return asset && asset.local_version || update && (update.local_version || update.source_version) || '';
}

function operationFor(asset, update) {
    var kind = asset && asset.kind;
    var local = asset && asset.update;

    if (local && local.status && local.status !== 'idle')
        return local;
    if (!update)
        return { kind: kind, status: 'idle' };
    if (update.kind === kind)
        return update;
    if (update.kind === 'all' && (update.status === 'starting' || update.status === 'running'))
        return update.current_kind === kind ? update : { kind: kind, status: 'queued' };

    return { kind: kind, status: 'idle' };
}

function progressText(operation) {
    var progress = operation && operation.progress || operation || {};
    var downloaded = Number(progress.downloaded || 0);
    var total = Number(progress.total || 0);

    if (total > 0)
        return _('Downloading %s%% · %s / %s').format(
            Math.max(0, Math.min(100, Math.round(downloaded * 100 / total))),
            nftflowUi.formatBytes(downloaded),
            nftflowUi.formatBytes(total)
        );
    if (downloaded > 0)
        return _('Downloading · %s').format(nftflowUi.formatBytes(downloaded));
    return _('Downloading...');
}

function checkLabel(result) {
    if (result.update_available === true)
        return { state: 'warn', text: _('Update available') };
    if (result.update_available === false)
        return { state: 'ok', text: _('Up to date') };
    return { state: 'notice', text: _('Checked') };
}

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    load: function() {
        return L.resolveDefault(callStatus(), { ok: false, error: _('Unable to read update status.') });
    },

    render: function(statusResult) {
        document.title = _('NftFlow | Updates');

        var automatic = E('span', { 'aria-live': 'polite' }, _('Loading automatic update status...'));
        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var tableBody = E('tbody');
        var rows = {};
        var monitorTasks = {};
        var monitorStops = {};
        var pageVisible = true;

        function setMessage(state, value) {
            nftflowUi.setState(message, state, value);
        }

        function updateAutomaticStatus(result) {
            var state = result && result.auto_update || {};

            if (state.scheduled !== true) {
                nftflowUi.setState(automatic, 'notice', _('GeoData automatic update: Not scheduled'));
                return;
            }
            if (state.due && state.due.length) {
                nftflowUi.setState(automatic, 'warn', _('GeoData automatic update: Due now'));
                return;
            }
            if (state.next_update) {
                nftflowUi.setState(automatic, 'ok', _('GeoData automatic update: Enabled · Next: %s').format(
                    new Date(Number(state.next_update) * 1000).toLocaleString()
                ));
                return;
            }
            nftflowUi.setState(automatic, 'ok', _('GeoData automatic update: Enabled'));
        }

        function updateVersion(row, asset) {
            var local = assetVersion(asset) || row.localVersion || '';
            if (local)
                row.localVersion = local;

            var text = row.localVersion || _('Unknown');
            if (row.remoteVersion && row.remoteVersion !== row.localVersion)
                text = _('%s → %s').format(text, row.remoteVersion);
            nftflowUi.setText(row.version, text);
        }

        function updateRow(row, asset, operation) {
            asset = asset || row.asset || { kind: row.kind };
            operation = operation || operationFor(asset, null);
            row.asset = asset;
            row.operation = operation;
            updateVersion(row, asset);

            if (operation.status === 'starting' || operation.status === 'running') {
                nftflowUi.setState(row.status, 'notice', progressText(operation));
                row.check.disabled = true;
                row.update.disabled = true;
            } else if (operation.status === 'queued') {
                nftflowUi.setState(row.status, 'notice', _('Waiting to download'));
                row.check.disabled = true;
                row.update.disabled = true;
            } else if (operation.status === 'failed') {
                nftflowUi.setState(row.status, 'error', operation.error
                    ? _('Update failed · %s').format(operation.error)
                    : _('Update failed'));
                row.check.disabled = false;
                row.update.disabled = false;
            } else {
                nftflowUi.setState(row.status, asset.ready ? 'ok' : 'notice', asset.ready ? _('Ready') : _('Missing'));
                row.check.disabled = false;
                row.update.disabled = false;
            }
        }

        function createGeoRow(kind) {
            var status = E('span', { 'aria-live': 'polite' }, _('Loading'));
            var version = E('span', { 'style': 'font-family: monospace;' });
            var check = E('button', {
                'class': 'btn cbi-button cbi-button-action',
                'type': 'button'
            }, _('Check'));
            var update = E('button', {
                'class': 'btn cbi-button cbi-button-apply',
                'type': 'button'
            }, _('Update'));
            var actions = E('div', {
                'style': 'display: inline-flex; flex-wrap: wrap; justify-content: flex-end; gap: .5rem;'
            }, [ check, update ]);
            var row = {
                kind: kind,
                status: status,
                version: version,
                check: check,
                update: update,
                asset: { kind: kind },
                localVersion: '',
                remoteVersion: ''
            };

            rows[kind] = row;
            check.addEventListener('click', ui.createHandlerFn(check, function() {
                return checkAsset(row);
            }));
            update.addEventListener('click', ui.createHandlerFn(update, function() {
                return updateAsset(row);
            }));
            updateRow(row, row.asset, { status: 'idle' });

            tableBody.appendChild(E('tr', { 'class': 'tr' }, [
                E('th', {
                    'class': 'th cbi-section-table-cell',
                    'data-title': _('Component'),
                    'style': 'width: 18%;'
                }, assetLabel(kind)),
                E('td', {
                    'class': 'td cbi-section-table-cell',
                    'data-title': _('Status'),
                    'style': 'width: 28%; text-align: center;'
                }, status),
                E('td', {
                    'class': 'td cbi-section-table-cell',
                    'data-title': _('Version'),
                    'style': 'width: 28%; text-align: center;'
                }, version),
                E('td', {
                    'class': 'td cbi-section-table-cell',
                    'data-title': _('Actions'),
                    'style': 'width: 26%; text-align: right; white-space: nowrap;'
                }, actions)
            ]));
        }

        function applySnapshot(result) {
            if (!result || result.ok !== true)
                throw new Error(nftflowUi.errorMessage(result, _('Unable to read update status.')));

            updateAutomaticStatus(result);
            var assets = result.assets || {};

            GEO_KINDS.forEach(function(kind) {
                var asset = assets[kind] || { kind: kind };
                updateRow(rows[kind], asset, operationFor(asset, result.update));
            });
            setMessage('', '');
            return result;
        }

        function checkAsset(row) {
            row.check.disabled = true;
            nftflowUi.setState(row.status, 'notice', _('Checking...'));

            return callCheck(row.kind).then(function(result) {
                return nftflowUi.requireOk(result, _('%s check failed.').format(assetLabel(row.kind)));
            }).then(function(result) {
                var checked = checkLabel(result);
                row.localVersion = result.local_version || assetVersion(result.local_asset) || row.localVersion;
                row.remoteVersion = result.remote_version || '';
                updateRow(row, result.local_asset || row.asset, { status: 'idle' });
                updateVersion(row, result.local_asset || row.asset);
                nftflowUi.setState(row.status, checked.state, checked.text);
                return result;
            }).catch(function(error) {
                nftflowUi.setState(row.status, 'error', nftflowUi.errorMessage(error, _('%s check failed.').format(assetLabel(row.kind))));
                return false;
            }).then(function(result) {
                if (!row.update.disabled)
                    row.check.disabled = false;
                return result;
            });
        }

        function monitorUpdate(row) {
            if (monitorTasks[row.kind])
                return monitorTasks[row.kind];

            var deadline = Date.now() + 10 * 60 * 1000;
            var task;
            var request = null;
            var finish;
            var monitoring = new Promise(function(resolve, reject) {
                finish = function(error, result) {
                    poll.remove(task);
                    delete monitorTasks[row.kind];
                    delete monitorStops[row.kind];
                    if (error)
                        reject(error);
                    else
                        resolve(result);
                };

                task = function() {
                    if (request)
                        return request;
                    if (!pageVisible) {
                        finish(new Error(_('Update monitoring stopped because the page was closed.')));
                        return Promise.resolve();
                    }
                    if (Date.now() >= deadline) {
                        finish(new Error(_('%s update timed out.').format(assetLabel(row.kind))));
                        return Promise.resolve();
                    }

                    request = callStatus().then(function(result) {
                        if (!pageVisible)
                            return null;
                        if (!result || result.ok !== true)
                            throw new Error(nftflowUi.errorMessage(result, _('Unable to read update status.')));

                        var assets = result.assets || {};
                        var asset = assets[row.kind] || row.asset;
                        var operation = operationFor(asset, result.update);

                        updateRow(row, asset, operation);
                        if (operation.status === 'done')
                            finish(null, result);
                        else if (operation.status === 'failed')
                            finish(new Error(operation.error || _('%s update failed.').format(assetLabel(row.kind))));
                        return result;
                    }).catch(function(error) {
                        if (Date.now() >= deadline)
                            finish(error);
                        else
                            nftflowUi.setState(row.status, 'notice', _('Retrying status...'));
                        return null;
                    }).then(function(result) {
                        request = null;
                        return result;
                    });

                    return request;
                };
            });

            monitorTasks[row.kind] = monitoring;
            monitorStops[row.kind] = function() {
                if (finish)
                    finish(new Error(_('Update monitoring stopped because the page was closed.')));
            };
            poll.add(task, L.env.pollinterval);
            task();
            return monitoring;
        }

        function updateAsset(row) {
            row.check.disabled = true;
            row.update.disabled = true;
            updateRow(row, row.asset, { status: 'starting' });

            return callUpdate(row.kind).then(function(result) {
                return nftflowUi.requireOk(result, _('%s update could not start.').format(assetLabel(row.kind)));
            }).then(function(result) {
                updateRow(row, row.asset, result);
                return monitorUpdate(row);
            }).then(function(result) {
                applySnapshot(result);
                return result;
            }).catch(function(error) {
                if (!pageVisible)
                    return false;
                updateRow(row, row.asset, { status: 'failed', error: nftflowUi.errorMessage(error) });
                return false;
            });
        }

        GEO_KINDS.forEach(createGeoRow);

        window.addEventListener('pagehide', function() {
            pageVisible = false;
            Object.keys(monitorStops).forEach(function(kind) {
                monitorStops[kind]();
            });
        }, { once: true });

        if (statusResult && statusResult.ok === true)
            applySnapshot(statusResult);
        else
            setMessage('error', nftflowUi.errorMessage(statusResult, _('Unable to read update status.')));

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Updates')),
            E('div', { 'class': 'cbi-map-descr' }, _('Check and install component updates. Update sources and local paths are configured in Settings.')),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('GeoData')),
                E('div', { 'class': 'cbi-section-descr' }, automatic),
                message,
                E('table', { 'class': 'table cbi-section-table' }, [
                    E('thead', {}, [ E('tr', { 'class': 'tr' }, [
                        E('th', { 'class': 'th', 'style': 'width: 18%;' }, _('Component')),
                        E('th', { 'class': 'th', 'style': 'width: 28%; text-align: center;' }, _('Status')),
                        E('th', { 'class': 'th', 'style': 'width: 28%; text-align: center;' }, _('Version')),
                        E('th', { 'class': 'th', 'style': 'width: 26%; text-align: right;' }, _('Actions'))
                    ]) ]),
                    tableBody
                ])
            ])
        ]);
    }
});
