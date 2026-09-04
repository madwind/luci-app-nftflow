'use strict';
'require view';
'require rpc';
'require uci';
'require nftflow.ui as nftflowUi';
'require nftflow.editor as nftflowEditor';
'require nftflow.nftformat as nftflowNftFormat';

var callRead = rpc.declare({ object: 'luci.nftflow', method: 'firewall_read', expect: { '': {} }, reject: true });
var callReady = rpc.declare({ object: 'luci.nftflow', method: 'firewall_ready', expect: { '': {} }, reject: true });
var callRuntime = rpc.declare({ object: 'luci.nftflow', method: 'firewall_runtime', expect: { '': {} }, reject: true });
var callValidate = rpc.declare({ object: 'luci.nftflow', method: 'firewall_validate', params: [ 'config' ], expect: { '': {} }, reject: true });
var callSave = rpc.declare({ object: 'luci.nftflow', method: 'firewall_save', params: [ 'config' ], expect: { '': {} }, reject: true });
var callApply = rpc.declare({ object: 'luci.nftflow', method: 'firewall_apply', params: [ 'config' ], expect: { '': {} }, reject: true });
var callDefault = rpc.declare({ object: 'luci.nftflow.defaults', method: 'firewall', expect: { '': {} }, reject: true });

function resultDetail(result, fallback) {
    var detail = [ result && result.error, result && result.detail ].filter(Boolean).join(': ');
    return detail || fallback;
}

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
        var port = String(uci.get('nftflow', 'main', 'listen_port') || '12345');
        var gid = String(uci.get('nftflow', 'main', 'run_gid') || '23333');
        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var runtimeState = E('span', { 'aria-live': 'polite' }, _('Loading...'));
        var runtimeRequest = null;
        var runtimeReadyTimer = null;
        var pageVisible = true;
        var editor;
        var activeEditor = nftflowEditor.create({
            id: 'nftflow-firewall-runtime',
            label: _('Current runtime rules'),
            minHeight: '18em',
            rows: 18,
            readonly: true
        });

        activeEditor.markSaved(_('# Runtime rules are loading.\n'));

        function setMessage(state, value) {
            nftflowUi.setState(message, state, value);
        }

        function updateRuntime(next) {
            activeEditor.markSaved(next && next.active
                ? next.active
                : _('# No active NftFlow nftables tables were found.\n'));
            nftflowUi.setState(runtimeState, 'ok', _('Loaded'));
        }

        function refreshRuntime(manual) {
            if (!pageVisible || runtimeRequest)
                return runtimeRequest || Promise.resolve();

            if (manual)
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

        function refreshRuntimeWhenReady(manual) {
            if (!pageVisible)
                return Promise.resolve();
            if (runtimeReadyTimer !== null) {
                window.clearTimeout(runtimeReadyTimer);
                runtimeReadyTimer = null;
            }

            return callReady().then(function(state) {
                if (state && state.ok === true && state.busy === true) {
                    nftflowUi.setState(runtimeState, 'notice', _('Waiting for service...'));
                    runtimeReadyTimer = window.setTimeout(function() {
                        runtimeReadyTimer = null;
                        refreshRuntimeWhenReady(false);
                    }, 1000);
                    return false;
                }
                return refreshRuntime(manual);
            }).catch(function() {
                return refreshRuntime(manual);
            });
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
                setMessage('notice', _('Default Firewall template loaded in the editor. Review before applying.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to read the default Firewall template.')));
                return false;
            });
        }

        function withinLimit(current) {
            if (current.withinLimit())
                return true;
            current.focus();
            setMessage('error', _('The Firewall file is larger than 32 KiB.'));
            return false;
        }

        function formatFirewall(current) {
            current.setValue(nftflowNftFormat.format(current.getValue()));
            current.focus();
            setMessage('ok', _('Formatted in the editor. Review before applying.'));
            return Promise.resolve(true);
        }

        function checkFirewall(current) {
            if (!withinLimit(current))
                return Promise.resolve(false);
            setMessage('notice', _('Checking Firewall syntax...'));
            return callValidate(current.getValue()).then(function(next) {
                if (!next || next.valid !== true)
                    throw new Error(resultDetail(next, _('Firewall syntax check failed.')));
                var warning = warningDetail(next);
                setMessage(warning ? 'warn' : 'ok', warning
                    ? _('Firewall syntax check passed with warning: %s').format(warning)
                    : _('Firewall syntax check passed.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Firewall syntax check failed.')));
                return false;
            });
        }

        function applyFirewall(current) {
            if (!withinLimit(current))
                return Promise.resolve(false);
            setMessage('notice', _('Applying Firewall rules to runtime...'));
            return callApply(current.getValue()).then(function(next) {
                return nftflowUi.requireOk(next, _('Unable to apply Firewall rules.'));
            }).then(function(next) {
                updateRuntime(next);
                var warning = warningDetail(next);
                setMessage(warning ? 'warn' : 'ok', warning
                    ? _('Applied to runtime with warning: %s').format(warning)
                    : _('Applied to runtime; the saved file was not changed.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to apply Firewall rules.')));
                return false;
            });
        }

        function applySaveFirewall(current) {
            if (!withinLimit(current))
                return Promise.resolve(false);

            var applied = false;
            var warning = '';
            var value = current.getValue();
            setMessage('notice', _('Applying Firewall rules and saving the file...'));

            return callApply(value).then(function(next) {
                return nftflowUi.requireOk(next, _('Unable to apply Firewall rules.'));
            }).then(function(next) {
                applied = true;
                warning = warningDetail(next);
                updateRuntime(next);
                return callSave(value);
            }).then(function(next) {
                return nftflowUi.requireOk(next, _('The Firewall file could not be saved.'));
            }).then(function(next) {
                warning = warning || warningDetail(next);
                current.markSaved(next.config === undefined ? value : next.config);
                setMessage(warning ? 'warn' : 'ok', warning
                    ? _('Applied and saved with warning: %s').format(warning)
                    : _('Applied to runtime and saved to the Firewall file.'));
                return true;
            }).catch(function(error) {
                var fallback = applied
                    ? _('Applied to runtime, but the Firewall file could not be saved.')
                    : _('Unable to apply Firewall rules.');
                setMessage('error', nftflowUi.errorMessage(error, fallback));
                return false;
            });
        }

        editor = nftflowEditor.create({
            id: 'nftflow-firewall-editor',
            label: _('nftables ruleset'),
            minHeight: '32em',
            rows: 32,
            format: formatFirewall,
            check: checkFirewall,
            loadDefault: loadDefaultFirewall,
            reload: reloadFirewall,
            apply: applyFirewall,
            applySave: applySaveFirewall
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
            refreshRuntimeWhenReady(true);
        });

        var runtimeToolbar = E('div', {
            'class': 'cbi-section-descr',
            'style': 'display:flex; align-items:center; justify-content:space-between; gap:1em'
        }, [ runtimeState, refreshButton ]);

        refreshRuntimeWhenReady(false);
        window.addEventListener('pagehide', function() {
            pageVisible = false;
            if (runtimeReadyTimer !== null)
                window.clearTimeout(runtimeReadyTimer);
        }, { once: true });

        var variablesHelp = E('div', { 'class': 'cbi-section-descr' }, [
            E('div', {}, _('Available variables:')),
            E('div', {}, [ E('code', {}, '%port%'), ' = ', E('code', {}, port) ]),
            E('div', {}, [ E('code', {}, '%gid%'), ' = ', E('code', {}, gid) ]),
            E('div', {}, [ E('code', {}, '%geoip:<tag>%') ])
        ]);

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Firewall')),
            E('div', { 'class': 'cbi-map-descr' }, _('Edit the nftables source. Apply changes temporarily or apply and save them permanently.')),
            E('div', { 'class': 'cbi-section' }, [ variablesHelp, editor.root, message ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Runtime rules')),
                runtimeToolbar,
                activeEditor.root
            ])
        ]);
    }
});
