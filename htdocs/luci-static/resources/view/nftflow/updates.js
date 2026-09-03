'use strict';
'require view';
'require poll';
'require rpc';
'require ui';
'require nftflow.ui as nftflowUi';

var callSoftwareStatus = rpc.declare({ object: 'luci.nftflow', method: 'update_status', expect: { '': {} }, reject: true });
var callGeoStatus = rpc.declare({ object: 'luci.nftflow', method: 'geo_status', expect: { '': {} }, reject: true });
var callUpdateCheck = rpc.declare({ object: 'luci.nftflow', method: 'update_check', params: [ 'kind' ], expect: { '': {} }, reject: true });
var callUpdateInstall = rpc.declare({ object: 'luci.nftflow', method: 'update_install', params: [ 'kind' ], expect: { '': {} }, reject: true });
var callUpdateStop = rpc.declare({ object: 'luci.nftflow', method: 'update_stop', params: [ 'kind' ], expect: { '': {} }, reject: true });
var callUpdateSettings = rpc.declare({ object: 'luci.nftflow', method: 'update_settings', expect: { '': {} }, reject: true });
var callSetCheck = rpc.declare({ object: 'luci.nftflow', method: 'update_set_check', params: [ 'enabled' ], expect: { '': {} }, reject: true });
var callSetAuto = rpc.declare({ object: 'luci.nftflow', method: 'update_set_auto', params: [ 'kind', 'enabled' ], expect: { '': {} }, reject: true });

var SOFTWARE_KINDS = [ 'nftflow', 'xray' ];
var GEO_KINDS = [ 'geoip', 'geosite' ];
var ALL_KINDS = SOFTWARE_KINDS.concat(GEO_KINDS);

function componentLabel(kind) {
    if (kind === 'nftflow') return _('NftFlow');
    if (kind === 'xray') return _('Xray Core');
    if (kind === 'geoip') return _('GeoIP');
    return _('GeoSite');
}

function activeStatus(status) {
    return [ 'starting', 'running', 'stopping' ].indexOf(status) >= 0;
}

function phaseText(operation) {
    var phase = operation && (operation.phase || operation.status) || '';
    if (phase === 'downloading') return _('Downloading...');
    if (phase === 'verifying') return _('Verifying...');
    if (phase === 'installing') return _('Installing...');
    if (phase === 'stopping') return _('Stopping...');
    return _('Updating...');
}

function formatTimestamp(value) {
    var seconds = Number(value || 0);
    if (!seconds) return '—';
    var delta = seconds - Date.now() / 1000;
    var absolute = Math.abs(delta);
    var unit = 'second', divisor = 1;
    if (absolute >= 365 * 86400) { unit = 'year'; divisor = 365 * 86400; }
    else if (absolute >= 30 * 86400) { unit = 'month'; divisor = 30 * 86400; }
    else if (absolute >= 86400) { unit = 'day'; divisor = 86400; }
    else if (absolute >= 3600) { unit = 'hour'; divisor = 3600; }
    else if (absolute >= 60) { unit = 'minute'; divisor = 60; }
    var amount = Math.round(delta / divisor);
    var locale = document.documentElement && document.documentElement.getAttribute('lang') || 'en';
    try {
        if (typeof Intl !== 'undefined' && typeof Intl.RelativeTimeFormat === 'function')
            return new Intl.RelativeTimeFormat(locale, { numeric: 'always' }).format(amount, unit);
    } catch (e) {}
    var count = Math.abs(amount), label = unit + (count === 1 ? '' : 's');
    return amount < 0 ? '%d %s ago'.format(count, label) : 'in %d %s'.format(count, label);
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
            L.resolveDefault(callUpdateSettings(), { ok: false, error: _('Unable to read update settings.') })
        ]);
    },

    render: function(data) {
        document.title = _('NftFlow | Updates');

        var softwareInitial = data && data[0];
        var geoInitial = data && data[1];
        var settingsInitial = data && data[2];
        var rows = {};
        var pageVisible = true;
        var checkingAll = false;
        var refreshBusy = false;
        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var checkEnabled = E('input', { 'type': 'checkbox', 'disabled': '' });
        var checkButton = E('button', { 'class': 'btn cbi-button cbi-button-action', 'type': 'button' }, _('Check updates'));
        var componentGrid = E('div', { 'class': 'nftflow-update-grid' });

        function setMessage(state, text) {
            nftflowUi.setState(message, state, text || '');
        }

        function anyActive() {
            return ALL_KINDS.some(function(kind) { return rows[kind] && rows[kind].active; });
        }

        function renderVersion(row) {
            row.version.replaceChildren(E('code', {}, row.installedVersion || _('Unknown')));
            if (row.latestVersion && row.latestVersion !== row.installedVersion) {
                row.version.appendChild(document.createTextNode(' → '));
                row.version.appendChild(E('code', {}, row.latestVersion));
            }
        }

        function renderHistory(row) {
            var history = [];
            if (row.checkedAt) history.push(_('Last check: %s').format(formatTimestamp(row.checkedAt)));
            if (row.lastUpdateAt) history.push(_('Last update: %s').format(formatTimestamp(row.lastUpdateAt)));
            nftflowUi.setText(row.history, history.join(' · '));
            row.history.hidden = history.length === 0;
        }

        function renderIdle(row, checkOk, checkError, fallback) {
            if (checkOk === false && checkError) nftflowUi.setState(row.status, 'error', checkError);
            else if (row.updateAvailable === true) nftflowUi.setState(row.status, 'warn', _('Update available'));
            else if (row.updateAvailable === false) nftflowUi.setState(row.status, 'ok', _('Up to date'));
            else nftflowUi.setState(row.status, 'notice', fallback || _('Not checked'));
        }

        function updateButtons(row, operation) {
            var active = activeStatus(operation && operation.status);
            row.active = active;
            row.update.disabled = active || checkingAll || row.updateAvailable !== true;
            if (!active) row.stop.disabled = true;
            else if (row.kind === 'xray') row.stop.disabled = true;
            else if (row.kind === 'nftflow' && operation.phase === 'installing') row.stop.disabled = true;
            else row.stop.disabled = operation.status === 'stopping';
            row.auto.disabled = false;
            checkButton.disabled = checkingAll || anyActive();
        }

        function updateRow(row, component, operation, fallback) {
            component = component || {};
            operation = operation || component.operation || component.update || {};
            if (component.installed_version) row.installedVersion = String(component.installed_version);
            if (component.local_version) row.installedVersion = String(component.local_version);
            if (component.latest_version) row.latestVersion = String(component.latest_version);
            if (component.check_ok === false) row.updateAvailable = null;
            else if (component.update_available !== undefined && component.update_available !== null)
                row.updateAvailable = component.update_available === true;
            if (component.checked != null) row.checkedAt = Number(component.checked) || 0;
            if (component.last_update != null) row.lastUpdateAt = Number(component.last_update) || 0;
            renderVersion(row);
            renderHistory(row);

            if (row.checking) nftflowUi.setState(row.status, 'notice', _('Checking for updates...'));
            else if (activeStatus(operation.status)) nftflowUi.setState(row.status, 'notice', phaseText(operation));
            else if (operation.status === 'failed') nftflowUi.setState(row.status, 'error', operation.error || _('Update failed'));
            else if (operation.status === 'stopped') nftflowUi.setState(row.status, 'notice', _('Stopped'));
            else if (operation.status === 'done' && operation.updated === true && component.post_check_error)
                nftflowUi.setState(row.status, 'warn', _('Updated') + ' · ' + component.post_check_error);
            else renderIdle(row, component.check_ok, component.last_check_error, fallback);
            updateButtons(row, operation);
        }

        function createRow(kind) {
            var row = {
                kind: kind,
                status: E('span', { 'aria-live': 'polite' }, _('Loading')),
                version: E('span'),
                history: E('div', { 'class': 'cbi-section-descr' }),
                auto: E('input', { 'type': 'checkbox', 'disabled': '' }),
                update: E('button', { 'class': 'btn cbi-button cbi-button-apply', 'type': 'button', 'disabled': '' }, _('Update')),
                stop: E('button', { 'class': 'btn cbi-button cbi-button-negative', 'type': 'button', 'disabled': '' }, _('Stop')),
                installedVersion: '',
                latestVersion: '',
                updateAvailable: null,
                checkedAt: 0,
                lastUpdateAt: 0,
                checking: false,
                active: false
            };
            row.history.hidden = true;
            row.auto.addEventListener('change', function() { setAuto(row); });
            row.update.addEventListener('click', ui.createHandlerFn(row.update, function() { return startUpdate(row); }));
            row.stop.addEventListener('click', ui.createHandlerFn(row.stop, function() { return stopUpdate(row); }));
            rows[kind] = row;
            componentGrid.appendChild(E('div', { 'class': 'cbi-section-node' }, [
                E('h4', {}, componentLabel(kind)),
                valueRow(_('Version'), row.version),
                valueRow(_('Status'), row.status),
                valueRow(_('Automatic update'), row.auto),
                valueRow(_('Actions'), E('span', {}, [ row.update, ' ', row.stop ])),
                row.history
            ]));
        }

        function applySoftware(result) {
            if (!result || result.ok !== true) throw new Error(nftflowUi.errorMessage(result, _('Unable to read software update status.')));
            var components = result.components || {};
            SOFTWARE_KINDS.forEach(function(kind) {
                var component = components[kind] || {};
                updateRow(rows[kind], component, component.operation || {}, _('Not checked'));
            });
            return result;
        }

        function applyGeo(result) {
            if (!result || result.ok !== true) throw new Error(nftflowUi.errorMessage(result, _('Unable to read GeoData update status.')));
            var assets = result.assets || {};
            GEO_KINDS.forEach(function(kind) {
                var asset = assets[kind] || {};
                updateRow(rows[kind], asset, asset.update || {}, asset.ready === false ? _('Missing') : _('Not checked'));
            });
            return result;
        }

        function applySettings(result) {
            if (!result || result.ok !== true) throw new Error(nftflowUi.errorMessage(result, _('Unable to read update settings.')));
            checkEnabled.checked = result.check_enabled === true || result.check_enabled === 1;
            checkEnabled.disabled = false;
            ALL_KINDS.forEach(function(kind) {
                rows[kind].auto.checked = result[kind] === true || result[kind] === 1;
                rows[kind].auto.disabled = false;
            });
            return result;
        }

        function refresh() {
            if (!pageVisible || checkingAll || refreshBusy) return Promise.resolve();
            refreshBusy = true;
            return Promise.all([
                L.resolveDefault(callSoftwareStatus(), null),
                L.resolveDefault(callGeoStatus(), null)
            ]).then(function(result) {
                if (result[0]) applySoftware(result[0]);
                if (result[1]) applyGeo(result[1]);
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to refresh update status.')));
            }).then(function() {
                refreshBusy = false;
            });
        }

        function applyCheckResult(row, result) {
            row.checking = false;
            if (SOFTWARE_KINDS.indexOf(row.kind) >= 0) {
                updateRow(row, {
                    installed_version: result.installed_version,
                    latest_version: result.latest_version,
                    update_available: result.update_available,
                    checked: result.checked,
                    check_ok: result.check_ok,
                    last_check_error: result.last_check_error,
                    last_update: result.last_update
                }, {}, _('Not checked'));
            } else {
                updateRow(row, {
                    local_version: result.local_version,
                    latest_version: result.remote_version,
                    update_available: result.update_available,
                    checked: result.checked,
                    check_ok: result.check_ok,
                    last_check_error: result.last_check_error,
                    last_update: result.last_update
                }, {}, _('Not checked'));
            }
        }

        function checkAll() {
            if (checkingAll || anyActive()) return Promise.resolve();
            checkingAll = true;
            checkButton.disabled = true;
            ALL_KINDS.forEach(function(kind) {
                rows[kind].checking = false;
                rows[kind].update.disabled = true;
            });
            setMessage('notice', _('Checking all components...'));
            var failures = [];
            var chain = Promise.resolve();
            ALL_KINDS.forEach(function(kind) {
                chain = chain.then(function() {
                    var row = rows[kind];
                    row.checking = true;
                    nftflowUi.setState(row.status, 'notice', _('Checking for updates...'));
                    return callUpdateCheck(kind).then(function(result) {
                        result = nftflowUi.requireOk(result, _('%s update check failed.').format(componentLabel(kind)));
                        applyCheckResult(row, result);
                    }).catch(function(error) {
                        row.checking = false;
                        row.updateAvailable = null;
                        row.update.disabled = true;
                        failures.push('%s: %s'.format(componentLabel(kind), nftflowUi.errorMessage(error, _('Check failed'))));
                        nftflowUi.setState(row.status, 'error', nftflowUi.errorMessage(error, _('Check failed')));
                    });
                });
            });
            return chain.then(function() {
                checkingAll = false;
                if (failures.length) setMessage('error', failures.join(' · '));
                else setMessage('ok', _('All update checks completed.'));
                return refresh();
            });
        }

        function startUpdate(row) {
            if (row.updateAvailable !== true || row.active) return Promise.resolve();
            row.update.disabled = true;
            checkButton.disabled = true;
            return callUpdateInstall(row.kind).then(function(result) {
                result = nftflowUi.requireOk(result, _('%s update could not start.').format(componentLabel(row.kind)));
                nftflowUi.setState(row.status, 'notice', phaseText(result));
                setMessage('notice', _('%s update started.').format(componentLabel(row.kind)));
                return refresh();
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('%s update could not start.').format(componentLabel(row.kind))));
                return refresh();
            });
        }

        function stopUpdate(row) {
            if (!row.active) return Promise.resolve();
            row.stop.disabled = true;
            nftflowUi.setState(row.status, 'notice', _('Stopping...'));
            return callUpdateStop(row.kind).then(function(result) {
                nftflowUi.requireOk(result, _('%s update could not be stopped.').format(componentLabel(row.kind)));
                return refresh();
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('%s update could not be stopped.').format(componentLabel(row.kind))));
                return refresh();
            });
        }

        function setCheck() {
            var desired = checkEnabled.checked;
            checkEnabled.disabled = true;
            return callSetCheck(desired ? 1 : 0).then(function(result) {
                applySettings(nftflowUi.requireOk(result, _('Unable to change automatic check setting.')));
            }).catch(function(error) {
                checkEnabled.checked = !desired;
                checkEnabled.disabled = false;
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to change automatic check setting.')));
            });
        }

        function setAuto(row) {
            var desired = row.auto.checked;
            row.auto.disabled = true;
            return callSetAuto(row.kind, desired ? 1 : 0).then(function(result) {
                applySettings(nftflowUi.requireOk(result, _('Unable to change automatic update setting.')));
            }).catch(function(error) {
                row.auto.checked = !desired;
                row.auto.disabled = false;
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to change automatic update setting.')));
            });
        }

        ALL_KINDS.forEach(createRow);
        checkEnabled.addEventListener('change', setCheck);
        checkButton.addEventListener('click', ui.createHandlerFn(checkButton, checkAll));

        if (softwareInitial && softwareInitial.ok === true) applySoftware(softwareInitial);
        else SOFTWARE_KINDS.forEach(function(kind) { nftflowUi.setState(rows[kind].status, 'error', nftflowUi.errorMessage(softwareInitial, _('Unable to read software update status.'))); });
        if (geoInitial && geoInitial.ok === true) applyGeo(geoInitial);
        else GEO_KINDS.forEach(function(kind) { nftflowUi.setState(rows[kind].status, 'error', nftflowUi.errorMessage(geoInitial, _('Unable to read GeoData update status.'))); });
        if (settingsInitial && settingsInitial.ok === true) applySettings(settingsInitial);
        else setMessage('error', nftflowUi.errorMessage(settingsInitial, _('Unable to read update settings.')));

        poll.add(refresh, 2);
        window.setInterval(function() { if (pageVisible) ALL_KINDS.forEach(function(kind) { renderHistory(rows[kind]); }); }, 60000);
        window.addEventListener('pagehide', function() { pageVisible = false; poll.remove(refresh); }, { once: true });

        var layoutStyle = E('style', { 'type': 'text/css' }, [
            '#nftflow-updates .nftflow-update-grid {display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1em;}' +
            '#nftflow-updates .nftflow-update-grid > .cbi-section-node {min-width:0;}' +
            '@media (max-width:800px) {#nftflow-updates .nftflow-update-grid {grid-template-columns:1fr;}}'
        ]);

        return E('div', { 'class': 'cbi-map', 'id': 'nftflow-updates' }, [
            layoutStyle,
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Updates')),
            E('div', { 'class': 'cbi-map-descr' }, _('Checks discover available versions. Updates install only a version already found by a check.')),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Update checks')),
                valueRow(_('Automatic update checks'), E('label', {}, [ checkEnabled, ' ', _('Weekly') ])),
                valueRow(_('Actions'), checkButton),
                message
            ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Components')),
                componentGrid
            ])
        ]);
    }
});
