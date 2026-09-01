'use strict';
'require view';
'require poll';
'require rpc';
'require ui';
'require nftflow.ui as nftflowUi';

var callGeoStatus = rpc.declare({ object: 'luci.nftflow', method: 'geo_status', expect: { '': {} }, reject: true });
var callGeoStop = rpc.declare({ object: 'luci.nftflow', method: 'geo_stop', params: [ 'kind' ], expect: { '': {} }, reject: true });
var callSoftwareStatus = rpc.declare({ object: 'luci.nftflow', method: 'update_status', expect: { '': {} }, reject: true });
var callSoftwareInstall = rpc.declare({ object: 'luci.nftflow', method: 'update_install', params: [ 'kind' ], expect: { '': {} }, reject: true });
var callSoftwareStop = rpc.declare({ object: 'luci.nftflow', method: 'update_stop', params: [ 'kind' ], expect: { '': {} }, reject: true });
var callGeoAutoStatus = rpc.declare({ object: 'luci.nftflow.geoops', method: 'status', expect: { '': {} }, reject: true });
var callGeoAutoSet = rpc.declare({ object: 'luci.nftflow.geoops', method: 'set_auto', params: [ 'kind', 'enabled' ], expect: { '': {} }, reject: true });
var callGeoSmartUpdate = rpc.declare({ object: 'luci.nftflow.geoops', method: 'update', params: [ 'kind' ], expect: { '': {} }, reject: true });

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
    if (local && local.status && local.status !== 'idle') return local;
    if (!update) return { kind: kind, status: 'idle' };
    if (update.kind === kind) return update;
    if (update.kind === 'all' && (update.status === 'starting' || update.status === 'running'))
        return update.current_kind === kind ? update : { kind: kind, status: 'queued' };
    return { kind: kind, status: 'idle' };
}

function progressText(operation) {
    var progress = operation && operation.progress || operation || {};
    var downloaded = Number(progress.downloaded || 0);
    var total = Number(progress.total || 0);
    if (total > 0)
        return _('Downloading %s%% · %s / %s').format(Math.max(0, Math.min(100, Math.round(downloaded * 100 / total))), nftflowUi.formatBytes(downloaded), nftflowUi.formatBytes(total));
    if (downloaded > 0) return _('Downloading · %s').format(nftflowUi.formatBytes(downloaded));
    return _('Downloading...');
}

function softwarePhase(operation) {
    var phase = operation && (operation.phase || operation.status) || '';
    if (phase === 'checking') return _('Checking for updates...');
    if (phase === 'downloading') return _('Downloading...');
    if (phase === 'verifying') return _('Verifying...');
    if (phase === 'installing') return _('Installing...');
    if (phase === 'stopping') return _('Stopping...');
    return _('Updating...');
}

function formatTimestamp(value) {
    var seconds = Number(value || 0);
    if (!seconds) return '—';
    try { return new Date(seconds * 1000).toLocaleString(); } catch (e) { return '—'; }
}

function valueRow(label, field) {
    return E('div', { 'class': 'cbi-value' }, [
        E('div', { 'class': 'cbi-value-title' }, label),
        E('div', { 'class': 'cbi-value-field' }, [ field ])
    ]);
}

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    load: function() {
        return Promise.all([
            L.resolveDefault(callSoftwareStatus(), { ok: false, error: _('Unable to read software update status.') }),
            L.resolveDefault(callGeoStatus(), { ok: false, error: _('Unable to read GeoData update status.') }),
            L.resolveDefault(callGeoAutoStatus(), { ok: false, error: _('Unable to read automatic GeoData update settings.') })
        ]);
    },

    render: function(data) {
        document.title = _('NftFlow | Updates');

        var softwareResult = data && data[0];
        var geoResult = data && data[1];
        var autoResult = data && data[2];
        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var componentGrid = E('div', { 'class': 'nftflow-update-grid' });
        var rows = {};
        var monitorTasks = {};
        var monitorStops = {};
        var pageVisible = true;

        function setMessage(state, value) {
            nftflowUi.setState(message, state, value);
        }

        function renderVersion(row) {
            var installed = row.installedVersion || '';
            var latest = row.latestVersion || '';
            row.version.replaceChildren(E('code', {}, installed || _('Unknown')));
            if (latest && latest !== installed) {
                row.version.appendChild(document.createTextNode(' → '));
                row.version.appendChild(E('code', {}, latest));
            }
        }

        function setVersions(row, installed, latest) {
            if (installed) row.installedVersion = installed;
            if (latest) row.latestVersion = latest;
            renderVersion(row);
        }

        function setRowMeta(row, checked, lastUpdate) {
            if (checked != null) row.checkedAt = Number(checked) || 0;
            if (lastUpdate != null) row.lastUpdateAt = Number(lastUpdate) || 0;
            var history = [];
            if (row.checkedAt) history.push(_('Last check: %s').format(formatTimestamp(row.checkedAt)));
            if (row.lastUpdateAt) history.push(_('Last update: %s').format(formatTimestamp(row.lastUpdateAt)));
            nftflowUi.setText(row.history, history.join(' · '));
            row.history.hidden = history.length === 0;
        }

        function setIdleStatus(row, available, fallback) {
            if (available === true) nftflowUi.setState(row.status, 'warn', _('Update available'));
            else if (available === false) nftflowUi.setState(row.status, 'ok', _('Up to date'));
            else nftflowUi.setState(row.status, 'notice', fallback || _('Ready'));
        }

        function softwareCanStop(kind, operation) {
            if (!operation || [ 'starting', 'running', 'stopping' ].indexOf(operation.status) < 0) return false;
            if (kind === 'xray') return false;
            return operation.phase !== 'installing' && operation.status !== 'stopping';
        }

        function updateSoftwareRow(row, component) {
            component = component || {};
            var operation = component.operation || {};
            if (component.update_available !== undefined) row.updateAvailable = component.update_available;
            setVersions(row, component.installed_version, component.latest_version);
            setRowMeta(row, component.checked, component.last_update);

            if ([ 'starting', 'running', 'stopping' ].indexOf(operation.status) >= 0) {
                nftflowUi.setState(row.status, 'notice', operation.status === 'stopping' ? _('Stopping...') : softwarePhase(operation));
                row.update.disabled = true;
                row.stop.disabled = !softwareCanStop(row.kind, operation);
                return;
            }
            if (operation.status === 'failed') nftflowUi.setState(row.status, 'error', operation.error || _('Update failed'));
            else if (operation.status === 'stopped') nftflowUi.setState(row.status, 'notice', _('Stopped'));
            else if (operation.status === 'done' && operation.updated === true && operation.post_check_error) nftflowUi.setState(row.status, 'warn', _('Updated · verification check failed'));
            else if (component.check_ok === false && component.last_check_error) nftflowUi.setState(row.status, 'error', component.last_check_error);
            else if (component.no_release === true) nftflowUi.setState(row.status, 'notice', _('No published release'));
            else setIdleStatus(row, row.updateAvailable, _('Ready'));
            row.update.disabled = false;
            row.stop.disabled = true;
        }

        function updateGeoRow(row, asset, operation) {
            asset = asset || row.asset || { kind: row.kind };
            operation = operation || geoOperation(asset, null);
            row.asset = asset;
            if (asset.ready === false) {
                row.updateAvailable = null;
                row.installedVersion = '';
            } else if (asset.update_available !== undefined) {
                row.updateAvailable = asset.update_available;
            }
            var local = geoVersion(asset) || row.installedVersion || '';
            if (local) row.installedVersion = local;
            setVersions(row, row.installedVersion, asset.latest_version || row.latestVersion);
            setRowMeta(row, asset.checked, asset.last_update);

            if ([ 'starting', 'running', 'stopping' ].indexOf(operation.status) >= 0) {
                nftflowUi.setState(row.status, 'notice', operation.status === 'stopping' ? _('Stopping...') : progressText(operation));
                row.update.disabled = true;
                row.stop.disabled = operation.status === 'stopping';
            } else if (operation.status === 'queued') {
                nftflowUi.setState(row.status, 'notice', _('Waiting to download'));
                row.update.disabled = true;
                row.stop.disabled = true;
            } else {
                if (operation.status === 'failed') nftflowUi.setState(row.status, 'error', operation.error || _('Update failed'));
                else if (operation.status === 'stopped') nftflowUi.setState(row.status, 'notice', _('Stopped'));
                else if (operation.status === 'done' && operation.updated === true && asset.post_check_error) nftflowUi.setState(row.status, 'warn', _('Updated · verification check failed'));
                else if (asset.check_ok === false && asset.last_check_error) nftflowUi.setState(row.status, 'error', asset.last_check_error);
                else setIdleStatus(row, row.updateAvailable, asset.ready ? _('Ready') : _('Missing'));
                row.update.disabled = false;
                row.stop.disabled = true;
            }
        }

        function createRow(kind) {
            var status = E('span', { 'aria-live': 'polite' }, _('Loading'));
            var version = E('span');
            var history = E('div', { 'class': 'cbi-section-descr' });
            var update = E('button', { 'class': 'btn cbi-button cbi-button-apply', 'type': 'button' }, _('Update'));
            var stop = E('button', { 'class': 'btn cbi-button cbi-button-negative', 'type': 'button', 'disabled': '' }, _('Stop'));
            var row = {
                kind: kind,
                status: status,
                version: version,
                history: history,
                update: update,
                stop: stop,
                installedVersion: '',
                latestVersion: '',
                updateAvailable: null,
                checkedAt: 0,
                lastUpdateAt: 0,
                asset: { kind: kind }
            };
            var children = [
                E('h4', {}, componentLabel(kind)),
                valueRow(_('Version'), version),
                valueRow(_('Status'), status)
            ];
            history.hidden = true;

            if (GEO_KINDS.indexOf(kind) >= 0) {
                row.auto = E('input', { 'type': 'checkbox', 'disabled': '' });
                children.push(valueRow(_('Automatic update'), E('label', {}, [ row.auto, ' ', _('Weekly') ])));
                row.auto.addEventListener('change', function() { setGeoAuto(row); });
            }

            children.push(valueRow(_('Actions'), E('span', {}, [ update, ' ', stop ])));
            children.push(history);
            rows[kind] = row;

            update.addEventListener('click', ui.createHandlerFn(update, function() {
                return SOFTWARE_KINDS.indexOf(kind) >= 0 ? installSoftware(row) : installGeo(row);
            }));
            stop.addEventListener('click', ui.createHandlerFn(stop, function() { return stopUpdate(row); }));
            componentGrid.appendChild(E('div', { 'class': 'cbi-section-node' }, children));
        }

        function applySoftwareSnapshot(result) {
            if (!result || result.ok !== true) throw new Error(nftflowUi.errorMessage(result, _('Unable to read software update status.')));
            var components = result.components || {};
            SOFTWARE_KINDS.forEach(function(kind) { updateSoftwareRow(rows[kind], components[kind] || { kind: kind }); });
            return result;
        }

        function applyGeoSnapshot(result) {
            if (!result || result.ok !== true) throw new Error(nftflowUi.errorMessage(result, _('Unable to read GeoData update status.')));
            var assets = result.assets || {};
            GEO_KINDS.forEach(function(kind) {
                var asset = assets[kind] || { kind: kind };
                updateGeoRow(rows[kind], asset, geoOperation(asset, result.update));
            });
            return result;
        }

        function applyAutoSnapshot(result) {
            if (!result || result.ok !== true) throw new Error(nftflowUi.errorMessage(result, _('Unable to read automatic GeoData update settings.')));
            GEO_KINDS.forEach(function(kind) {
                rows[kind].auto.checked = result[kind] === true || result[kind] === 1;
                rows[kind].auto.disabled = false;
            });
            return result;
        }

        function setGeoAuto(row) {
            var desired = row.auto.checked;
            row.auto.disabled = true;
            return callGeoAutoSet(row.kind, desired ? 1 : 0).then(function(result) {
                return nftflowUi.requireOk(result, _('Unable to change automatic update setting.'));
            }).then(applyAutoSnapshot).catch(function(error) {
                row.auto.checked = !desired;
                row.auto.disabled = false;
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to change automatic update setting.')));
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
                    if (!pageVisible) { finish(new Error(_('Update monitoring stopped because the page was closed.'))); return Promise.resolve(); }
                    if (Date.now() >= deadline) { finish(new Error(_('%s update timed out.').format(componentLabel(row.kind)))); return Promise.resolve(); }
                    request = statusCall().then(function(result) {
                        if (!result || result.ok !== true) throw new Error(nftflowUi.errorMessage(result, _('Unable to read update status.')));
                        applySnapshot(result);
                        var operation = operationForResult(result);
                        if (operation.status === 'done' || operation.status === 'stopped') finish(null, result);
                        else if (operation.status === 'failed') finish(new Error(operation.error || _('Update failed')));
                        return result;
                    }).catch(function(error) {
                        if (Date.now() >= deadline) finish(error);
                        else nftflowUi.setState(row.status, 'notice', _('Reconnecting...'));
                        return null;
                    }).then(function(result) { request = null; return result; });
                    return request;
                };
            });
            monitorTasks[row.kind] = monitoring;
            monitorStops[row.kind] = function() { if (finish) finish(new Error(_('Update monitoring stopped because the page was closed.'))); };
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
            row.update.disabled = true;
            row.stop.disabled = true;
            nftflowUi.setState(row.status, 'notice', _('Checking for updates...'));
            return callSoftwareInstall(row.kind).then(function(result) {
                result = nftflowUi.requireOk(result, _('%s update could not start.').format(componentLabel(row.kind)));
                updateSoftwareRow(row, { installed_version: row.installedVersion, latest_version: row.latestVersion, update_available: row.updateAvailable, operation: result });
                return monitorSoftware(row);
            }).catch(function(error) {
                if (!pageVisible) return false;
                nftflowUi.setState(row.status, 'error', nftflowUi.errorMessage(error, _('%s update failed.').format(componentLabel(row.kind))));
                row.update.disabled = false;
                row.stop.disabled = true;
                return false;
            });
        }

        function installGeo(row) {
            row.update.disabled = true;
            row.stop.disabled = true;
            nftflowUi.setState(row.status, 'notice', _('Checking for updates...'));
            return callGeoSmartUpdate(row.kind).then(function(result) {
                result = nftflowUi.requireOk(result, _('%s update could not start.').format(componentLabel(row.kind)));
                if ([ 'starting', 'running' ].indexOf(result.status) < 0)
                    return callGeoStatus().then(applyGeoSnapshot);
                updateGeoRow(row, row.asset, result);
                return monitorGeo(row);
            }).catch(function(error) {
                if (!pageVisible) return false;
                nftflowUi.setState(row.status, 'error', nftflowUi.errorMessage(error, _('%s update failed.').format(componentLabel(row.kind))));
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

        ALL_KINDS.forEach(createRow);

        if (softwareResult && softwareResult.ok === true) applySoftwareSnapshot(softwareResult);
        else SOFTWARE_KINDS.forEach(function(kind) { nftflowUi.setState(rows[kind].status, 'error', nftflowUi.errorMessage(softwareResult, _('Unable to read software update status.'))); });

        if (geoResult && geoResult.ok === true) applyGeoSnapshot(geoResult);
        else GEO_KINDS.forEach(function(kind) { nftflowUi.setState(rows[kind].status, 'error', nftflowUi.errorMessage(geoResult, _('Unable to read GeoData update status.'))); });

        if (autoResult && autoResult.ok === true) applyAutoSnapshot(autoResult);
        else setMessage('error', nftflowUi.errorMessage(autoResult, _('Unable to read automatic GeoData update settings.')));

        window.addEventListener('pagehide', function() {
            pageVisible = false;
            Object.keys(monitorStops).forEach(function(kind) { monitorStops[kind](); });
        }, { once: true });

        var layoutStyle = E('style', { 'type': 'text/css' }, [
            '#nftflow-updates .nftflow-update-grid {display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1em;}' +
            '#nftflow-updates .nftflow-update-grid > .cbi-section-node {min-width:0;}' +
            '@media (max-width:800px) {#nftflow-updates .nftflow-update-grid {grid-template-columns:1fr;}}'
        ]);

        return E('div', { 'class': 'cbi-map', 'id': 'nftflow-updates' }, [
            layoutStyle,
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Updates')),
            E('div', { 'class': 'cbi-map-descr' }, _('Update NftFlow, Xray Core and GeoData. Each Update checks for a newer version first. Update sources and local paths are configured in Settings.')),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Components')),
                message,
                componentGrid
            ])
        ]);
    }
});
