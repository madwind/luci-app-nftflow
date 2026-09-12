'use strict';
'require view';
'require poll';
'require rpc';
'require nftflow.ui as nftflowUi';

var callStatus = rpc.declare({ object: 'luci.nftflow', method: 'update_status', expect: { '': {} }, reject: true });
var callCheck = rpc.declare({ object: 'luci.nftflow', method: 'update_check', expect: { '': {} }, reject: true });
var callInstall = rpc.declare({ object: 'luci.nftflow', method: 'update_install', expect: { '': {} }, reject: true });
var callSettings = rpc.declare({ object: 'luci.nftflow', method: 'update_settings', expect: { '': {} }, reject: true });
var callSetCheck = rpc.declare({ object: 'luci.nftflow', method: 'update_set_check', params: [ 'enabled' ], expect: { '': {} }, reject: true });
var callSetAuto = rpc.declare({ object: 'luci.nftflow', method: 'update_set_auto', params: [ 'enabled' ], expect: { '': {} }, reject: true });

function valueRow(title, field) {
    return E('div', { 'class': 'cbi-value' }, [
        E('div', { 'class': 'cbi-value-title' }, title),
        E('div', { 'class': 'cbi-value-field' }, [ field ])
    ]);
}

function active(component) {
    return component && (component.status === 'starting' || component.status === 'running');
}

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    load: function() {
        return Promise.all([
            L.resolveDefault(callStatus(), { ok: false, error: _('Unable to read update status.') }),
            L.resolveDefault(callSettings(), { ok: false, error: _('Unable to read update settings.') })
        ]);
    },

    render: function(data) {
        document.title = _('NftFlow | Updates');

        var scheduleEnabled = E('input', { 'type': 'checkbox' });
        var scheduleState = E('span');
        var row = null;
        var refreshBusy = false;

        function versionText(component) {
            var installed = component.installed_version || _('Unknown');
            var latest = component.latest_version || '';
            return latest && latest !== installed ? installed + ' → ' + latest : installed;
        }

        function renderComponent(component) {
            component = component || {};
            row.active = active(component);
            if (component.update_available === true) row.available = true;
            else if (component.update_available === false) row.available = false;
            else row.available = null;
            nftflowUi.setText(row.version, versionText(component));

            if (row.checking) {
                nftflowUi.setState(row.status, 'notice', _('Checking for updates...'));
            } else if (row.active) {
                nftflowUi.setState(row.status, 'notice', component.status === 'starting' ? _('Starting...') : _('Updating...'));
            } else if (component.status === 'failed' || (component.ok === false && component.error)) {
                nftflowUi.setState(row.status, 'error', component.error || _('Update failed'));
            } else if (component.status === 'done' && component.updated === true) {
                nftflowUi.setState(row.status, 'ok', _('Updated'));
            } else if (row.available === true) {
                nftflowUi.setState(row.status, 'warn', _('Update available'));
            } else if (row.available === false) {
                nftflowUi.setState(row.status, 'ok', _('Up to date'));
            } else {
                nftflowUi.setState(row.status, 'notice', _('Not checked'));
            }

            row.update.disabled = row.checking || row.active;
        }

        function applyStatus(result) {
            if (!result || result.ok !== true)
                throw new Error(nftflowUi.errorMessage(result, _('Unable to read update status.')));
            renderComponent(result.component || {});
            return result;
        }

        function applySettings(result) {
            if (!result || result.ok !== true)
                throw new Error(nftflowUi.errorMessage(result, _('Unable to read update settings.')));
            scheduleEnabled.checked = result.check_enabled === true || result.check_enabled === 1;
            nftflowUi.setText(scheduleState, result.scheduled ? _('Weekly schedule active') : _('Weekly schedule disabled'));
            row.auto.checked = result.auto_update === true || result.auto_update === 1;
            return result;
        }

        function setStatusError(error, fallback) {
            row.checking = false;
            row.active = false;
            row.available = null;
            row.update.disabled = false;
            nftflowUi.setState(row.status, 'error', nftflowUi.errorMessage(error, fallback));
        }

        function refresh() {
            if (refreshBusy) return Promise.resolve();
            refreshBusy = true;
            return callStatus().then(applyStatus).catch(function(error) {
                setStatusError(error, _('Unable to read update status.'));
            }).finally(function() {
                refreshBusy = false;
            });
        }

        function refreshCheck() {
            if (row.checking || row.active) return Promise.resolve(null);

            row.checking = true;
            row.update.disabled = true;
            nftflowUi.setState(row.status, 'notice', _('Checking for updates...'));

            return callCheck().then(function(result) {
                row.checking = false;
                if (!result || result.ok !== true)
                    throw new Error(nftflowUi.errorMessage(result, _('NftFlow update check failed.')));
                renderComponent(result);
                return result;
            }).catch(function(error) {
                setStatusError(error, _('NftFlow update check failed.'));
                return null;
            });
        }

        function installUpdate() {
            if (row.active) return Promise.resolve();

            row.update.disabled = true;
            nftflowUi.setState(row.status, 'notice', _('Starting NftFlow update...'));
            return callInstall().then(function(result) {
                if (!result || result.ok !== true)
                    throw new Error(nftflowUi.errorMessage(result, _('NftFlow update could not be started.')));
                return refresh();
            }).catch(function(error) {
                setStatusError(error, _('NftFlow update could not be started.'));
            });
        }

        function runUpdate() {
            if (row.checking || row.active) return Promise.resolve();

            return refreshCheck().then(function(result) {
                if (result && result.update_available === true)
                    return installUpdate();
                return result;
            });
        }

        function setAuto(input) {
            input.disabled = true;
            return callSetAuto(input.checked ? 1 : 0).then(function(result) {
                applySettings(result);
            }).catch(function(error) {
                nftflowUi.setState(row.status, 'error', nftflowUi.errorMessage(error, _('Unable to save automatic update setting.')));
            }).finally(function() {
                input.disabled = false;
            });
        }

        function createRow() {
            row = {
                version: E('span'),
                status: E('span', { 'aria-live': 'polite' }, _('Loading')),
                auto: E('input', { 'type': 'checkbox' }),
                update: E('button', { 'class': 'btn cbi-button cbi-button-apply', 'type': 'button' }, _('Update')),
                active: false,
                checking: false,
                available: null
            };
            row.auto.addEventListener('change', function() { setAuto(row.auto); });
            row.update.addEventListener('click', runUpdate);
            return E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('NftFlow')),
                valueRow(_('Version / state'), row.version),
                valueRow(_('Status'), row.status),
                valueRow(_('Automatic update'), row.auto),
                valueRow(_('Actions'), row.update)
            ]);
        }

        scheduleEnabled.addEventListener('change', function() {
            scheduleEnabled.disabled = true;
            callSetCheck(scheduleEnabled.checked ? 1 : 0).then(function() {
                return callSettings();
            }).then(applySettings).catch(function(error) {
                nftflowUi.setState(scheduleState, 'error', nftflowUi.errorMessage(error, _('Unable to save update schedule.')));
            }).finally(function() {
                scheduleEnabled.disabled = false;
            });
        });

        var componentRow = createRow();
        var root = E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Updates')),
            E('div', { 'class': 'cbi-map-descr' }, _('NftFlow updates only its own package. Managed runtime programs and optional data files remain under user control.')),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Automatic updates')),
                valueRow(_('Weekly update schedule'), E('span', {}, [ scheduleEnabled, ' ', scheduleState ]))
            ]),
            componentRow
        ]);

        try { applyStatus(data && data[0]); } catch (e) { setStatusError(e, _('Unable to read update status.')); }
        try { applySettings(data && data[1]); } catch (e) { nftflowUi.setState(scheduleState, 'error', nftflowUi.errorMessage(e, _('Unable to read update settings.'))); }

        if (!row.active)
            refreshCheck();

        poll.add(function() {
            return row.active ? refresh() : Promise.resolve();
        }, 2);

        return root;
    }
});
