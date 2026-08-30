'use strict';
'require view';
'require poll';
'require rpc';
'require ui';
'require nftflow.ui as nftflowUi';

var callGeoStatus = rpc.declare({
    object: 'luci.nftflow',
    method: 'geo_status',
    expect: { '': {} },
    reject: true
});

var callGeoCheck = rpc.declare({
    object: 'luci.nftflow',
    method: 'geo_check',
    params: [ 'kind' ],
    expect: { '': {} },
    reject: true
});

var callGeoUpdate = rpc.declare({
    object: 'luci.nftflow',
    method: 'geo_update',
    params: [ 'kind' ],
    expect: { '': {} },
    reject: true
});

var callSoftwareStatus = rpc.declare({
    object: 'luci.nftflow',
    method: 'update_status',
    expect: { '': {} },
    reject: true
});

var callSoftwareCheck = rpc.declare({
    object: 'luci.nftflow',
    method: 'update_check',
    params: [ 'kind' ],
    expect: { '': {} },
    reject: true
});

var callSoftwareInstall = rpc.declare({
    object: 'luci.nftflow',
    method: 'update_install',
    params: [ 'kind' ],
    expect: { '': {} },
    reject: true
});

var SOFTWARE_KINDS = [ 'nftflow', 'xray' ];
var GEO_KINDS = [ 'geoip', 'geosite' ];
var ALL_KINDS = SOFTWARE_KINDS.concat(GEO_KINDS);

function componentLabel(kind) {
    if (kind === 'nftflow') return _('NftFlow');
    if (kind === 'xray') return _('Xray Core');
    if (kind === 'geoip') return _('GeoIP');
    return _('GeoSite');
}

function geoVersion(asset) {
    var update = asset && asset.update;
    return asset && asset.local_version || update && (update.local_version || update.source_version) || '';
}

function geoOperation(asset, update) {
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

function softwarePhase(operation) {
    var phase = operation && operation.phase || operation && operation.status || '';
    if (phase === 'checking') return _('Checking...');
    if (phase === 'downloading') return _('Downloading...');
    if (phase === 'verifying') return _('Verifying...');
    if (phase === 'installing') return _('Installing...');
    if (phase === 'starting') return _('Starting update...');
    return _('Updating...');
}

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    load: function() {
        return Promise.all([
            L.resolveDefault(callSoftwareStatus(), { ok: false, error: _('Unable to read software update status.') }),
            L.resolveDefault(callGeoStatus(), { ok: false, error: _('Unable to read GeoData update status.') })
        ]);
    },

    render: function(data) {
        document.title = _('NftFlow | Updates');

        var softwareResult = data && data[0];
        var geoResult = data && data[1];
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

        function setAutomatic(result) {
            var state = result && result.auto_update || {};
            if (state.scheduled !== true) {
                nftflowUi.setState(automatic, 'notice', _('GeoData automatic update: Not scheduled'));
                return;
            }
            nftflowUi.setState(automatic, 'ok', _('GeoData automatic update: Weekly'));
        }

        function setVersions(row, installed, latest) {
            row.installedVersion = installed || row.installedVersion || '';
            row.latestVersion = latest || row.latestVersion || '';
            nftflowUi.setText(row.installed, row.installedVersion || _('Unknown'));
            nftflowUi.setText(row.latest, row.latestVersion || '—');
        }

        function setIdleStatus(row, available, fallback) {
            if (available === true)
                nftflowUi.setState(row.status, 'warn', _('Update available'));
            else if (available === false)
                nftflowUi.setState(row.status, 'ok', _('Up to date'));
            else
                nftflowUi.setState(row.status, 'notice', fallback || _('Not checked'));
        }

        function updateSoftwareRow(row, component) {
            component = component || {};
            var operation = component.operation || {};
            setVersions(row, component.installed_version, component.latest_version);

            if (operation.status === 'starting' || operation.status === 'running') {
                nftflowUi.setState(row.status, 'notice', softwarePhase(operation));
                row.check.disabled = true;
                row.update.disabled = true;
                return;
            }
            if (operation.status === 'failed') {
                nftflowUi.setState(row.status, 'error', operation.error || _('Update failed'));
                row.check.disabled = false;
                row.update.disabled = false;
                return;
            }
            if (operation.status === 'done' && operation.message) {
                if (operation.updated === true)
                    nftflowUi.setState(row.status, 'ok', operation.message);
                else
                    setIdleStatus(row, component.update_available, operation.message);
            } else if (component.no_release === true) {
                nftflowUi.setState(row.status, 'notice', _('No published release'));
            } else {
                setIdleStatus(row, component.update_available);
            }
            row.check.disabled = false;
            row.update.disabled = component.update_available === false || component.no_release === true;
        }

        function updateGeoRow(row, asset, operation) {
            asset = asset || row.asset || { kind: row.kind };
            operation = operation || geoOperation(asset, null);
            row.asset = asset;
            var local = geoVersion(asset) || row.installedVersion || '';
            if (local) row.installedVersion = local;
            setVersions(row, row.installedVersion, row.latestVersion);

            if (operation.status === 'starting' || operation.status === 'running') {
                nftflowUi.setState(row.status, 'notice', progressText(operation));
                row.check.disabled = true;
                row.update.disabled = true;
            } else if (operation.status === 'queued') {
                nftflowUi.setState(row.status, 'notice', _('Waiting to download'));
                row.check.disabled = true;
                row.update.disabled = true;
            } else if (operation.status === 'failed') {
                nftflowUi.setState(row.status, 'error', operation.error || _('Update failed'));
                row.check.disabled = false;
                row.update.disabled = false;
            } else {
                setIdleStatus(row, row.updateAvailable, asset.ready ? _('Ready') : _('Missing'));
                row.check.disabled = false;
                row.update.disabled = false;
            }
        }

        function createRow(kind) {
            var status = E('span', { 'aria-live': 'polite' }, _('Loading'));
            var installed = E('span', { 'style': 'font-family: monospace;' });
            var latest = E('span', { 'style': 'font-family: monospace;' });
            var check = E('button', {
                'class': 'btn cbi-button cbi-button-action',
                'type': 'button'
            }, _('Check'));
            var update = E('button', {
                'class': 'btn cbi-button cbi-button-apply',
                'type': 'button'
            }, _('Update'));
            var row = {
                kind: kind,
                status: status,
                installed: installed,
                latest: latest,
                check: check,
                update: update,
                installedVersion: '',
                latestVersion: '',
                updateAvailable: null,
                asset: { kind: kind }
            };

            rows[kind] = row;
            check.addEventListener('click', ui.createHandlerFn(check, function() {
                return SOFTWARE_KINDS.indexOf(kind) >= 0 ? checkSoftware(row) : checkGeo(row);
            }));
            update.addEventListener('click', ui.createHandlerFn(update, function() {
                return SOFTWARE_KINDS.indexOf(kind) >= 0 ? installSoftware(row) : installGeo(row);
            }));

            tableBody.appendChild(E('tr', { 'class': 'tr' }, [
                E('th', { 'class': 'th cbi-section-table-cell', 'data-title': _('Component'), 'style': 'width: 18%;' }, componentLabel(kind)),
                E('td', { 'class': 'td cbi-section-table-cell', 'data-title': _('Installed'), 'style': 'width: 18%; text-align: center;' }, installed),
                E('td', { 'class': 'td cbi-section-table-cell', 'data-title': _('Latest'), 'style': 'width: 18%; text-align: center;' }, latest),
                E('td', { 'class': 'td cbi-section-table-cell', 'data-title': _('Status'), 'style': 'width: 24%; text-align: center;' }, status),
                E('td', { 'class': 'td cbi-section-table-cell', 'data-title': _('Actions'), 'style': 'width: 22%; text-align: right; white-space: nowrap;' }, [
                    E('div', { 'style': 'display: inline-flex; flex-wrap: wrap; justify-content: flex-end; gap: .5rem;' }, [ check, update ])
                ])
            ]));
        }

        function applySoftwareSnapshot(result) {
            if (!result || result.ok !== true)
                throw new Error(nftflowUi.errorMessage(result, _('Unable to read software update status.')));
            var components = result.components || {};
            SOFTWARE_KINDS.forEach(function(kind) {
                updateSoftwareRow(rows[kind], components[kind] || { kind: kind });
            });
            return result;
        }

        function applyGeoSnapshot(result) {
            if (!result || result.ok !== true)
                throw new Error(nftflowUi.errorMessage(result, _('Unable to read GeoData update status.')));
            setAutomatic(result);
            var assets = result.assets || {};
            GEO_KINDS.forEach(function(kind) {
                var asset = assets[kind] || { kind: kind };
                updateGeoRow(rows[kind], asset, geoOperation(asset, result.update));
            });
            return result;
        }

        function checkSoftware(row) {
            row.check.disabled = true;
            row.update.disabled = true;
            nftflowUi.setState(row.status, 'notice', _('Checking...'));
            return callSoftwareCheck(row.kind).then(function(result) {
                return nftflowUi.requireOk(result, _('%s check failed.').format(componentLabel(row.kind)));
            }).then(function(result) {
                row.updateAvailable = result.update_available;
                updateSoftwareRow(row, {
                    installed_version: result.installed_version,
                    latest_version: result.latest_version,
                    update_available: result.update_available,
                    no_release: result.no_release,
                    operation: { status: 'idle' }
                });
                return result;
            }).catch(function(error) {
                nftflowUi.setState(row.status, 'error', nftflowUi.errorMessage(error, _('%s check failed.').format(componentLabel(row.kind))));
                row.check.disabled = false;
                row.update.disabled = false;
                return false;
            });
        }

        function checkGeo(row) {
            row.check.disabled = true;
            nftflowUi.setState(row.status, 'notice', _('Checking...'));
            return callGeoCheck(row.kind).then(function(result) {
                return nftflowUi.requireOk(result, _('%s check failed.').format(componentLabel(row.kind)));
            }).then(function(result) {
                row.installedVersion = result.local_version || geoVersion(result.local_asset) || row.installedVersion;
                row.latestVersion = result.remote_version || row.latestVersion;
                row.updateAvailable = result.update_available;
                updateGeoRow(row, result.local_asset || row.asset, { status: 'idle' });
                return result;
            }).catch(function(error) {
                nftflowUi.setState(row.status, 'error', nftflowUi.errorMessage(error, _('%s check failed.').format(componentLabel(row.kind))));
                row.check.disabled = false;
                return false;
            });
        }

        function monitorSoftware(row) {
            if (monitorTasks[row.kind]) return monitorTasks[row.kind];
            var deadline = Date.now() + 5 * 60 * 1000;
            var task;
            var request = null;
            var finish;
            var monitoring = new Promise(function(resolve, reject) {
                finish = function(error, result) {
                    poll.remove(task);
                    delete monitorTasks[row.kind];
                    delete monitorStops[row.kind];
                    if (error) reject(error); else resolve(result);
                };
                task = function() {
                    if (request) return request;
                    if (!pageVisible) {
                        finish(new Error(_('Update monitoring stopped because the page was closed.')));
                        return Promise.resolve();
                    }
                    if (Date.now() >= deadline) {
                        finish(new Error(_('%s update timed out.').format(componentLabel(row.kind))));
                        return Promise.resolve();
                    }
                    request = callSoftwareStatus().then(function(result) {
                        if (!result || result.ok !== true)
                            throw new Error(nftflowUi.errorMessage(result, _('Unable to read software update status.')));
                        var component = result.components && result.components[row.kind] || {};
                        updateSoftwareRow(row, component);
                        var operation = component.operation || {};
                        if (operation.status === 'done') finish(null, result);
                        else if (operation.status === 'failed') finish(new Error(operation.error || _('Update failed')));
                        return result;
                    }).catch(function(error) {
                        if (Date.now() >= deadline) finish(error);
                        else nftflowUi.setState(row.status, 'notice', _('Reconnecting...'));
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
                if (finish) finish(new Error(_('Update monitoring stopped because the page was closed.')));
            };
            poll.add(task, L.env.pollinterval);
            task();
            return monitoring;
        }

        function monitorGeo(row) {
            if (monitorTasks[row.kind]) return monitorTasks[row.kind];
            var deadline = Date.now() + 10 * 60 * 1000;
            var task;
            var request = null;
            var finish;
            var monitoring = new Promise(function(resolve, reject) {
                finish = function(error, result) {
                    poll.remove(task);
                    delete monitorTasks[row.kind];
                    delete monitorStops[row.kind];
                    if (error) reject(error); else resolve(result);
                };
                task = function() {
                    if (request) return request;
                    if (!pageVisible) {
                        finish(new Error(_('Update monitoring stopped because the page was closed.')));
                        return Promise.resolve();
                    }
                    if (Date.now() >= deadline) {
                        finish(new Error(_('%s update timed out.').format(componentLabel(row.kind))));
                        return Promise.resolve();
                    }
                    request = callGeoStatus().then(function(result) {
                        if (!result || result.ok !== true)
                            throw new Error(nftflowUi.errorMessage(result, _('Unable to read GeoData update status.')));
                        var asset = result.assets && result.assets[row.kind] || row.asset;
                        var operation = geoOperation(asset, result.update);
                        updateGeoRow(row, asset, operation);
                        if (operation.status === 'done') finish(null, result);
                        else if (operation.status === 'failed') finish(new Error(operation.error || _('Update failed')));
                        return result;
                    }).catch(function(error) {
                        if (Date.now() >= deadline) finish(error);
                        else nftflowUi.setState(row.status, 'notice', _('Retrying status...'));
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
                if (finish) finish(new Error(_('Update monitoring stopped because the page was closed.')));
            };
            poll.add(task, L.env.pollinterval);
            task();
            return monitoring;
        }

        function installSoftware(row) {
            row.check.disabled = true;
            row.update.disabled = true;
            nftflowUi.setState(row.status, 'notice', _('Starting update...'));
            return callSoftwareInstall(row.kind).then(function(result) {
                return nftflowUi.requireOk(result, _('%s update could not start.').format(componentLabel(row.kind)));
            }).then(function() {
                return monitorSoftware(row);
            }).catch(function(error) {
                if (!pageVisible) return false;
                nftflowUi.setState(row.status, 'error', nftflowUi.errorMessage(error, _('%s update failed.').format(componentLabel(row.kind))));
                row.check.disabled = false;
                row.update.disabled = false;
                return false;
            });
        }

        function installGeo(row) {
            row.check.disabled = true;
            row.update.disabled = true;
            updateGeoRow(row, row.asset, { status: 'starting' });
            return callGeoUpdate(row.kind).then(function(result) {
                return nftflowUi.requireOk(result, _('%s update could not start.').format(componentLabel(row.kind)));
            }).then(function() {
                return monitorGeo(row);
            }).then(function(result) {
                applyGeoSnapshot(result);
                return result;
            }).catch(function(error) {
                if (!pageVisible) return false;
                nftflowUi.setState(row.status, 'error', nftflowUi.errorMessage(error, _('%s update failed.').format(componentLabel(row.kind))));
                row.check.disabled = false;
                row.update.disabled = false;
                return false;
            });
        }

        ALL_KINDS.forEach(createRow);

        if (softwareResult && softwareResult.ok === true)
            applySoftwareSnapshot(softwareResult);
        else {
            SOFTWARE_KINDS.forEach(function(kind) {
                nftflowUi.setState(rows[kind].status, 'error', nftflowUi.errorMessage(softwareResult, _('Unable to read software update status.')));
            });
        }

        if (geoResult && geoResult.ok === true)
            applyGeoSnapshot(geoResult);
        else {
            GEO_KINDS.forEach(function(kind) {
                nftflowUi.setState(rows[kind].status, 'error', nftflowUi.errorMessage(geoResult, _('Unable to read GeoData update status.')));
            });
        }

        window.addEventListener('pagehide', function() {
            pageVisible = false;
            Object.keys(monitorStops).forEach(function(kind) { monitorStops[kind](); });
        }, { once: true });

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Updates')),
            E('div', { 'class': 'cbi-map-descr' }, _('Check and install NftFlow, Xray Core and GeoData updates. Update sources and local paths are configured in Settings.')),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Components')),
                E('div', { 'class': 'cbi-section-descr' }, automatic),
                message,
                E('table', { 'class': 'table cbi-section-table' }, [
                    E('thead', {}, [ E('tr', { 'class': 'tr' }, [
                        E('th', { 'class': 'th', 'style': 'width: 18%;' }, _('Component')),
                        E('th', { 'class': 'th', 'style': 'width: 18%; text-align: center;' }, _('Installed')),
                        E('th', { 'class': 'th', 'style': 'width: 18%; text-align: center;' }, _('Latest')),
                        E('th', { 'class': 'th', 'style': 'width: 24%; text-align: center;' }, _('Status')),
                        E('th', { 'class': 'th', 'style': 'width: 22%; text-align: right;' }, _('Actions'))
                    ]) ]),
                    tableBody
                ])
            ])
        ]);
    }
});
