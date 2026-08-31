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

var callGeoStop = rpc.declare({
    object: 'luci.nftflow',
    method: 'geo_stop',
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

var callSoftwareStop = rpc.declare({
    object: 'luci.nftflow',
    method: 'update_stop',
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
    if (phase === 'stopping') return _('Stopping...');
    if (phase === 'starting') return _('Starting update...');
    return _('Updating...');
}

function formatTimestamp(value) {
    var seconds = Number(value || 0);
    if (!seconds) return '—';
    try {
        return new Date(seconds * 1000).toLocaleString();
    } catch (e) {
        return '—';
    }
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
        var componentSections = E('div');
        var rows = {};
        var monitorTasks = {};
        var monitorStops = {};
        var pageVisible = true;
        var checkAll = E('button', {
            'class': 'btn cbi-button cbi-button-action',
            'type': 'button'
        }, _('Check All'));

        function setMessage(state, value) {
            nftflowUi.setState(message, state, value);
        }

        function setAutomatic(result) {
            var state = result && result.auto_update || {};
            if (state.scheduled !== true) {
                nftflowUi.setState(automatic, 'notice', _('GeoData automatic update: Not scheduled'));
                return;
            }
            var next = state.next_update ? formatTimestamp(state.next_update) : '—';
            nftflowUi.setState(automatic, 'ok', _('GeoData automatic update: Weekly · Next: %s').format(next));
        }

        function setVersions(row, installed, latest) {
            if (installed) row.installedVersion = installed;
            if (latest) row.latestVersion = latest;
            nftflowUi.setText(row.installed, row.installedVersion || _('Unknown'));
            nftflowUi.setText(row.latest, row.latestVersion || '—');
        }

        function setRowMeta(row, checked, lastUpdate) {
            if (checked != null) row.checkedAt = Number(checked) || 0;
            if (lastUpdate != null) row.lastUpdateAt = Number(lastUpdate) || 0;
            nftflowUi.setText(row.lastCheck, formatTimestamp(row.checkedAt));
            nftflowUi.setText(row.lastUpdate, formatTimestamp(row.lastUpdateAt));
        }

        function setIdleStatus(row, available, fallback) {
            if (available === true)
                nftflowUi.setState(row.status, 'warn', _('Update available'));
            else if (available === false)
                nftflowUi.setState(row.status, 'ok', _('Up to date'));
            else
                nftflowUi.setState(row.status, 'notice', fallback || _('Not checked'));
        }

        function softwareCanStop(kind, operation) {
            if (!operation || (operation.status !== 'starting' && operation.status !== 'running' && operation.status !== 'stopping'))
                return false;
            if (kind === 'xray') return false;
            return operation.phase !== 'installing';
        }

        function updateSoftwareRow(row, component) {
            component = component || {};
            var operation = component.operation || {};
            row.updateAvailable = component.update_available;
            setVersions(row, component.installed_version, component.latest_version);
            setRowMeta(row, component.checked, component.last_update);

            if (operation.status === 'starting' || operation.status === 'running' || operation.status === 'stopping') {
                nftflowUi.setState(row.status, 'notice', operation.status === 'stopping' ? _('Stopping...') : softwarePhase(operation));
                row.check.disabled = true;
                row.update.disabled = true;
                row.stop.disabled = !softwareCanStop(row.kind, operation);
                return;
            }
            if (operation.status === 'failed') {
                nftflowUi.setState(row.status, 'error', operation.error || _('Update failed'));
            } else if (operation.status === 'stopped') {
                nftflowUi.setState(row.status, 'notice', _('Stopped'));
            } else if (operation.status === 'done' && operation.updated === true && operation.post_check_error) {
                nftflowUi.setState(row.status, 'warn', _('Updated · verification check failed'));
            } else if (component.no_release === true) {
                nftflowUi.setState(row.status, 'notice', _('No published release'));
            } else {
                setIdleStatus(row, component.update_available, component.checked ? null : _('Not checked'));
            }
            row.check.disabled = false;
            row.update.disabled = component.update_available === false || component.no_release === true;
            row.stop.disabled = true;
        }

        function updateGeoRow(row, asset, operation) {
            asset = asset || row.asset || { kind: row.kind };
            operation = operation || geoOperation(asset, null);
            row.asset = asset;
            row.updateAvailable = asset.update_available;
            var local = geoVersion(asset) || row.installedVersion || '';
            if (local) row.installedVersion = local;
            setVersions(row, row.installedVersion, asset.latest_version || row.latestVersion);
            setRowMeta(row, asset.checked, asset.last_update);

            if (operation.status === 'starting' || operation.status === 'running' || operation.status === 'stopping') {
                nftflowUi.setState(row.status, 'notice', operation.status === 'stopping' ? _('Stopping...') : progressText(operation));
                row.check.disabled = true;
                row.update.disabled = true;
                row.stop.disabled = operation.status === 'stopping';
            } else if (operation.status === 'queued') {
                nftflowUi.setState(row.status, 'notice', _('Waiting to download'));
                row.check.disabled = true;
                row.update.disabled = true;
                row.stop.disabled = true;
            } else if (operation.status === 'failed') {
                nftflowUi.setState(row.status, 'error', operation.error || _('Update failed'));
                row.check.disabled = false;
                row.update.disabled = false;
                row.stop.disabled = true;
            } else if (operation.status === 'stopped') {
                nftflowUi.setState(row.status, 'notice', _('Stopped'));
                row.check.disabled = false;
                row.update.disabled = false;
                row.stop.disabled = true;
            } else if (operation.status === 'done' && operation.updated === true && asset.post_check_error) {
                nftflowUi.setState(row.status, 'warn', _('Updated · verification check failed'));
                row.check.disabled = false;
                row.update.disabled = row.updateAvailable === false;
                row.stop.disabled = true;
            } else {
                setIdleStatus(row, row.updateAvailable, asset.ready ? _('Not checked') : _('Missing'));
                row.check.disabled = false;
                row.update.disabled = row.updateAvailable === false;
                row.stop.disabled = true;
            }
        }

        function valueRow(label, field) {
            return E('div', { 'class': 'cbi-value' }, [
                E('div', { 'class': 'cbi-value-title' }, label),
                E('div', { 'class': 'cbi-value-field' }, [ field ])
            ]);
        }

        function createRow(kind) {
            var status = E('span', { 'aria-live': 'polite' }, _('Loading'));
            var lastCheck = E('span', {}, '—');
            var lastUpdate = E('span', {}, '—');
            var installed = E('code', {}, '—');
            var latest = E('code', {}, '—');
            var check = E('button', {
                'class': 'btn cbi-button cbi-button-action',
                'type': 'button'
            }, _('Check'));
            var update = E('button', {
                'class': 'btn cbi-button cbi-button-apply',
                'type': 'button'
            }, _('Update'));
            var stop = E('button', {
                'class': 'btn cbi-button cbi-button-negative',
                'type': 'button',
                'disabled': ''
            }, _('Stop'));
            var actions = E('span', {}, [ check, ' ', update, ' ', stop ]);
            var row = {
                kind: kind,
                status: status,
                lastCheck: lastCheck,
                lastUpdate: lastUpdate,
                installed: installed,
                latest: latest,
                check: check,
                update: update,
                stop: stop,
                installedVersion: '',
                latestVersion: '',
                updateAvailable: null,
                checkedAt: 0,
                lastUpdateAt: 0,
                asset: { kind: kind }
            };

            rows[kind] = row;
            check.addEventListener('click', ui.createHandlerFn(check, function() {
                return SOFTWARE_KINDS.indexOf(kind) >= 0 ? checkSoftware(row) : checkGeo(row);
            }));
            update.addEventListener('click', ui.createHandlerFn(update, function() {
                return SOFTWARE_KINDS.indexOf(kind) >= 0 ? installSoftware(row) : installGeo(row);
            }));
            stop.addEventListener('click', ui.createHandlerFn(stop, function() {
                return stopUpdate(row);
            }));

            componentSections.appendChild(E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, componentLabel(kind)),
                E('div', { 'class': 'cbi-section-node' }, [
                    valueRow(_('Installed'), installed),
                    valueRow(_('Latest'), latest),
                    valueRow(_('Status'), status),
                    valueRow(_('Last check'), lastCheck),
                    valueRow(_('Last update'), lastUpdate),
                    valueRow(_('Actions'), actions)
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
            row.stop.disabled = true;
            nftflowUi.setState(row.status, 'notice', _('Checking...'));
            return callSoftwareCheck(row.kind).then(function(result) {
                return nftflowUi.requireOk(result, _('%s check failed.').format(componentLabel(row.kind)));
            }).then(function(result) {
                updateSoftwareRow(row, {
                    installed_version: result.installed_version,
                    latest_version: result.latest_version,
                    update_available: result.update_available,
                    no_release: result.no_release,
                    checked: result.checked,
                    last_update: result.last_update,
                    operation: { status: 'idle' }
                });
                return result;
            }).catch(function(error) {
                nftflowUi.setState(row.status, 'error', nftflowUi.errorMessage(error, _('%s check failed.').format(componentLabel(row.kind))));
                row.check.disabled = false;
                row.update.disabled = false;
                row.stop.disabled = true;
                return false;
            });
        }

        function checkGeo(row) {
            row.check.disabled = true;
            row.update.disabled = true;
            row.stop.disabled = true;
            nftflowUi.setState(row.status, 'notice', _('Checking...'));
            return callGeoCheck(row.kind).then(function(result) {
                return nftflowUi.requireOk(result, _('%s check failed.').format(componentLabel(row.kind)));
            }).then(function(result) {
                row.installedVersion = result.local_version || geoVersion(result.local_asset) || row.installedVersion;
                row.latestVersion = result.remote_version || row.latestVersion;
                var asset = result.local_asset || row.asset || { kind: row.kind };
                asset.latest_version = row.latestVersion;
                asset.update_available = result.update_available;
                asset.checked = result.checked;
                asset.last_update = result.last_update;
                updateGeoRow(row, asset, { status: 'idle' });
                return result;
            }).catch(function(error) {
                nftflowUi.setState(row.status, 'error', nftflowUi.errorMessage(error, _('%s check failed.').format(componentLabel(row.kind))));
                row.check.disabled = false;
                row.update.disabled = false;
                row.stop.disabled = true;
                return false;
            });
        }

        function monitor(row, statusCall, applySnapshot, operationForResult, timeoutMs) {
            if (monitorTasks[row.kind]) return monitorTasks[row.kind];
            var deadline = Date.now() + timeoutMs;
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
                    request = statusCall().then(function(result) {
                        if (!result || result.ok !== true)
                            throw new Error(nftflowUi.errorMessage(result, _('Unable to read update status.')));
                        applySnapshot(result);
                        var operation = operationForResult(result);
                        if (operation.status === 'done' || operation.status === 'stopped') finish(null, result);
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

        function monitorSoftware(row) {
            return monitor(row, callSoftwareStatus, applySoftwareSnapshot, function(result) {
                return result.components && result.components[row.kind] && result.components[row.kind].operation || {};
            }, 5 * 60 * 1000);
        }

        function monitorGeo(row) {
            return monitor(row, callGeoStatus, applyGeoSnapshot, function(result) {
                var asset = result.assets && result.assets[row.kind] || row.asset;
                return geoOperation(asset, result.update);
            }, 10 * 60 * 1000);
        }

        function installSoftware(row) {
            row.check.disabled = true;
            row.update.disabled = true;
            row.stop.disabled = true;
            nftflowUi.setState(row.status, 'notice', _('Starting update...'));
            return callSoftwareInstall(row.kind).then(function(result) {
                result = nftflowUi.requireOk(result, _('%s update could not start.').format(componentLabel(row.kind)));
                updateSoftwareRow(row, {
                    installed_version: row.installedVersion,
                    latest_version: row.latestVersion,
                    update_available: row.updateAvailable,
                    operation: result
                });
                return monitorSoftware(row);
            }).catch(function(error) {
                if (!pageVisible) return false;
                nftflowUi.setState(row.status, 'error', nftflowUi.errorMessage(error, _('%s update failed.').format(componentLabel(row.kind))));
                row.check.disabled = false;
                row.update.disabled = false;
                row.stop.disabled = true;
                return false;
            });
        }

        function installGeo(row) {
            row.check.disabled = true;
            row.update.disabled = true;
            updateGeoRow(row, row.asset, { status: 'starting' });
            return callGeoUpdate(row.kind).then(function(result) {
                result = nftflowUi.requireOk(result, _('%s update could not start.').format(componentLabel(row.kind)));
                updateGeoRow(row, row.asset, result);
                return monitorGeo(row);
            }).catch(function(error) {
                if (!pageVisible) return false;
                nftflowUi.setState(row.status, 'error', nftflowUi.errorMessage(error, _('%s update failed.').format(componentLabel(row.kind))));
                row.check.disabled = false;
                row.update.disabled = false;
                row.stop.disabled = true;
                return false;
            });
        }

        function stopUpdate(row) {
            row.stop.disabled = true;
            nftflowUi.setState(row.status, 'notice', _('Stopping...'));
            var software = SOFTWARE_KINDS.indexOf(row.kind) >= 0;
            var call = software ? callSoftwareStop : callGeoStop;
            return call(row.kind).then(function(result) {
                return nftflowUi.requireOk(result, _('%s update could not be stopped.').format(componentLabel(row.kind)));
            }).then(function() {
                return software ? callSoftwareStatus().then(applySoftwareSnapshot) : callGeoStatus().then(applyGeoSnapshot);
            }).catch(function(error) {
                nftflowUi.setState(row.status, 'error', nftflowUi.errorMessage(error, _('%s update could not be stopped.').format(componentLabel(row.kind))));
                row.stop.disabled = false;
                return false;
            });
        }

        function checkAllComponents() {
            checkAll.disabled = true;
            setMessage('notice', _('Checking all components...'));
            var chain = Promise.resolve();
            ALL_KINDS.forEach(function(kind) {
                chain = chain.then(function() {
                    var row = rows[kind];
                    return SOFTWARE_KINDS.indexOf(kind) >= 0 ? checkSoftware(row) : checkGeo(row);
                });
            });
            return chain.then(function() {
                setMessage('ok', _('All component checks finished.'));
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Component checks failed.')));
            }).then(function() {
                checkAll.disabled = false;
            });
        }

        ALL_KINDS.forEach(createRow);
        checkAll.addEventListener('click', ui.createHandlerFn(checkAll, checkAllComponents));

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
                E('div', { 'class': 'cbi-page-actions' }, [ checkAll ])
            ]),
            componentSections
        ]);
    }
});