'use strict';
'require view';
'require rpc';
'require uci';
'require nftflow.ui as nftflowUi';
'require nftflow.editor as nftflowEditor';
'require nftflow.nftformat as nftflowNftFormat';

var callRead = rpc.declare({ object: 'luci.nftflow', method: 'firewall_read', expect: { '': {} }, reject: true });
var callRuntime = rpc.declare({ object: 'luci.nftflow', method: 'firewall_runtime', expect: { '': {} }, reject: true });
var callActionStatus = rpc.declare({ object: 'luci.nftflow', method: 'firewall_action_status', expect: { '': {} }, reject: true });
var callSave = rpc.declare({ object: 'luci.nftflow', method: 'firewall_save', params: [ 'config' ], expect: { '': {} }, reject: true });
var callInstall = rpc.declare({ object: 'luci.nftflow', method: 'firewall_install', expect: { '': {} }, reject: true });
var callUninstall = rpc.declare({ object: 'luci.nftflow', method: 'firewall_uninstall', expect: { '': {} }, reject: true });
var callDefault = rpc.declare({ object: 'luci.nftflow.defaults', method: 'firewall', expect: { '': {} }, reject: true });

function warningDetail(result) {
    var warnings = result && Array.isArray(result.warnings) ? result.warnings : [];
    return warnings.filter(Boolean).join('; ');
}

return view.extend({
    load: function() {
        return Promise.all([
            L.resolveDefault(callRead(), { ok: false, error: _('Unable to read the Firewall file.') }),
            L.resolveDefault(uci.load('nftflow'), null)
        ]);
    },

    render: function(data) {
        document.title = _('NftFlow | Firewall');

        var result = data && data[0] || {};
        var gid = String(uci.get('nftflow', 'main', 'run_gid') || '23333');
        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var runtimeState = E('span', { 'aria-live': 'polite' }, _('Not loaded'));
        var runtimeRequest = null;
        var pageVisible = true;
        var actionInProgress = false;
        var editor;
        var activeEditor = nftflowEditor.create({
            id: 'nftflow-firewall-runtime',
            label: _('Current runtime rules'),
            minHeight: '18em',
            rows: 18,
            readonly: true
        });

        activeEditor.markSaved(_('# Runtime rules are not loaded yet.\n'));

        function setMessage(state, value) {
            nftflowUi.setState(message, state, value);
        }

        function invalidateRuntime() {
            activeEditor.markSaved(_('# Runtime rules are not loaded yet.\n'));
            nftflowUi.setState(runtimeState, 'notice', _('Not loaded'));
        }

        function updateRuntime(next) {
            var active = next && next.firewall_active === true;
            activeEditor.markSaved(next && next.active
                ? next.active
                : _('# No active NftFlow nftables tables were found.\n'));
            nftflowUi.setState(runtimeState, active ? 'ok' : 'notice', active ? _('Installed') : _('Not installed'));
            if (editor)
                editor.setInstalled(active);
        }

        function refreshRuntime() {
            if (!pageVisible || runtimeRequest)
                return runtimeRequest || Promise.resolve();

            nftflowUi.setState(runtimeState, 'notice', _('Refreshing...'));
            runtimeRequest = callRuntime().then(function(next) {
                return nftflowUi.requireOk(next, _('Unable to read runtime Firewall rules.'));
            }).then(function(next) {
                updateRuntime(next);
                return next;
            }).catch(function(error) {
                nftflowUi.setState(runtimeState, 'warn', nftflowUi.errorMessage(error, _('Runtime refresh failed.')));
                return false;
            }).then(function(next) {
                runtimeRequest = null;
                return next;
            });

            return runtimeRequest;
        }

        function reloadFirewall(current) {
            setMessage('notice', _('Reloading the saved Firewall file...'));
            return callRead().then(function(next) {
                return nftflowUi.requireOk(next, _('Unable to read the Firewall file.'));
            }).then(function(next) {
                current.markSaved(next.config || '');
                setMessage('ok', _('Saved Firewall file reloaded.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to read the Firewall file.')));
                return false;
            });
        }

        function loadDefaultFirewall(current) {
            setMessage('notice', _('Loading default Firewall template...'));
            return callDefault().then(function(next) {
                return nftflowUi.requireOk(next, _('Unable to read the default Firewall template.'));
            }).then(function(next) {
                current.setValue(next.config || '');
                current.focus();
                setMessage('notice', _('Default Firewall template loaded in the editor. Review before saving.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to read the default Firewall template.')));
                return false;
            });
        }

        function formatFirewall(current) {
            current.setValue(nftflowNftFormat.format(current.getValue()));
            current.focus();
            setMessage('ok', _('Formatted in the editor. Review before saving.'));
            return Promise.resolve(true);
        }

        function saveFirewall(current) {
            var value = current.getValue();
            setMessage('notice', _('Saving Firewall file...'));

            return callSave(value).then(function(next) {
                return nftflowUi.requireOk(next, _('The Firewall file could not be saved.'));
            }).then(function(next) {
                current.markSaved(next.config === undefined ? value : next.config);
                var warning = warningDetail(next);
                setMessage(warning ? 'warn' : 'ok', warning
                    ? _('Saved with warning: %s').format(warning)
                    : _('Firewall file saved.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('The Firewall file could not be saved.')));
                return false;
            });
        }

        function actionText(operation) {
            return operation === 'install' ? _('Installing Firewall rules...') : _('Uninstalling Firewall rules...');
        }

        function waitForFirewallAction(operation, started) {
            if (!pageVisible)
                return Promise.resolve(false);

            return callActionStatus().then(function(state) {
                return nftflowUi.requireOk(state, _('Unable to read Firewall action status.'));
            }).then(function(state) {
                if (String(state.operation || '') !== operation || Number(state.started || 0) !== Number(started || 0))
                    throw new Error(_('Firewall action state changed unexpectedly.'));

                if (state.status === 'starting' || state.status === 'running') {
                    setMessage('notice', actionText(operation));
                    return new Promise(function(resolve) {
                        window.setTimeout(resolve, 1000);
                    }).then(function() {
                        return waitForFirewallAction(operation, started);
                    });
                }

                var actionResult = state.result || {};
                if (state.status === 'failed' || actionResult.ok === false)
                    throw new Error(nftflowUi.errorMessage(actionResult, _('Firewall action failed.')));
                if (state.status !== 'done')
                    throw new Error(_('Firewall action ended in an unknown state.'));

                var warning = warningDetail(actionResult);
                invalidateRuntime();
                setMessage(warning ? 'warn' : 'ok', operation === 'install'
                    ? (warning ? _('Firewall installed with warning: %s').format(warning) : _('Firewall installed.'))
                    : _('Firewall uninstalled.'));
                return refreshRuntime();
            });
        }

        function startFirewallAction(operation) {
            if (actionInProgress)
                return Promise.resolve(false);

            actionInProgress = true;
            setMessage('notice', actionText(operation));
            var start = operation === 'install' ? callInstall : callUninstall;

            return start().then(function(next) {
                return nftflowUi.requireOk(next, operation === 'install'
                    ? _('Firewall rules could not be installed.')
                    : _('Firewall rules could not be uninstalled.'));
            }).then(function(next) {
                if (next.accepted !== true)
                    throw new Error(_('Firewall action was not accepted.'));
                return waitForFirewallAction(operation, next.started);
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Firewall action failed.')));
                return false;
            }).then(function(value) {
                actionInProgress = false;
                return value;
            });
        }

        function installFirewall(current) {
            if (current.isDirty()) {
                current.focus();
                setMessage('error', _('Save the Firewall file before installing it.'));
                return Promise.resolve(false);
            }
            return startFirewallAction('install');
        }

        function uninstallFirewall() {
            return startFirewallAction('uninstall');
        }

        function toggleFirewall(current, installed) {
            return installed ? uninstallFirewall() : installFirewall(current);
        }

        editor = nftflowEditor.create({
            id: 'nftflow-firewall-editor',
            label: _('nftables ruleset'),
            minHeight: '32em',
            rows: 32,
            format: formatFirewall,
            loadDefault: loadDefaultFirewall,
            reload: reloadFirewall,
            save: saveFirewall,
            installToggle: toggleFirewall
        });

        if (result && result.ok === true) {
            editor.markSaved(result.config || '');
        } else {
            setMessage('error', nftflowUi.errorMessage(result, _('Unable to read the Firewall file.')));
        }

        var refreshButton = E('button', {
            'class': 'btn cbi-button cbi-button-action',
            'type': 'button'
        }, _('Refresh'));
        refreshButton.addEventListener('click', function() {
            refreshRuntime();
        });

        var runtimeToolbar = E('div', {
            'class': 'cbi-section-descr',
            'style': 'display:flex; align-items:center; justify-content:space-between; gap:1em'
        }, [ runtimeState, refreshButton ]);

        window.addEventListener('pagehide', function() {
            pageVisible = false;
        }, { once: true });

        refreshRuntime();

        var variablesHelp = E('div', { 'class': 'cbi-section-descr' }, [
            E('div', {}, _('Available variables:')),
            E('div', {}, [ E('code', {}, '%gid%'), ' = ', E('code', {}, gid) ]),
            E('div', {}, [ E('code', {}, '%geoip:<tag>%') ])
        ]);

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Firewall')),
            E('div', { 'class': 'cbi-map-descr' }, _('Edit and save the nftables source. Use the editor toggle to install or uninstall it manually. NftFlow automatically installs saved rules when the service starts and removes them when it stops or exits unexpectedly.')),
            E('div', { 'class': 'cbi-section' }, [ variablesHelp, editor.root, message ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Runtime rules')),
                runtimeToolbar,
                activeEditor.root
            ])
        ]);
    }
});
