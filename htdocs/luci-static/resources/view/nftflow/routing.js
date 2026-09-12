'use strict';
'require view';
'require rpc';
'require nftflow.ui as nftflowUi';
'require nftflow.editor as nftflowEditor';

var callRead = rpc.declare({
    object: 'luci.nftflow',
    method: 'routing_read',
    expect: { '': {} },
    reject: true
});

var callRuntime = rpc.declare({
    object: 'luci.nftflow',
    method: 'routing_runtime',
    expect: { '': {} },
    reject: true
});

var callSave = rpc.declare({
    object: 'luci.nftflow',
    method: 'routing_save',
    params: [ 'config' ],
    expect: { '': {} },
    reject: true
});

var callInstall = rpc.declare({
    object: 'luci.nftflow',
    method: 'routing_install',
    expect: { '': {} },
    reject: true
});

var callUninstall = rpc.declare({
    object: 'luci.nftflow',
    method: 'routing_uninstall',
    expect: { '': {} },
    reject: true
});

var callDefault = rpc.declare({
    object: 'luci.nftflow.defaults',
    method: 'routing',
    expect: { '': {} },
    reject: true
});

function formatRouting(source) {
    var input = String(source || '').replace(/\r\n?/g, '\n').split('\n');
    var output = [];
    var blank = false;

    input.forEach(function(line) {
        var value = line.trim();
        if (!value) {
            if (output.length && !blank) {
                output.push('');
                blank = true;
            }
            return;
        }
        output.push(value);
        blank = false;
    });

    while (output.length && output[output.length - 1] === '')
        output.pop();

    return output.join('\n') + (output.length ? '\n' : '');
}

return view.extend({
    load: function() {
        return L.resolveDefault(callRead(), { ok: false, error: _('Unable to read the Routing file.') });
    },

    render: function(result) {
        document.title = _('NftFlow | Routing');

        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var runtimeState = E('span', { 'aria-live': 'polite' }, _('Not loaded'));
        var runtimeRequest = null;
        var pageVisible = true;
        var editor;
        var activeEditor = nftflowEditor.create({
            id: 'nftflow-routing-active',
            label: _('Active kernel commands'),
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
            var active = next && next.route_active === true;
            activeEditor.markSaved(next && next.active
                ? next.active
                : _('# No active policy routing commands are installed.\n'));
            nftflowUi.setState(runtimeState, active ? 'ok' : 'notice', active ? _('Installed') : _('Not installed'));
            if (editor)
                editor.setInstalled(active);
        }

        function refreshRuntime() {
            if (!pageVisible || runtimeRequest)
                return runtimeRequest || Promise.resolve();

            nftflowUi.setState(runtimeState, 'notice', _('Refreshing...'));
            runtimeRequest = callRuntime().then(function(next) {
                return nftflowUi.requireOk(next, _('Unable to read runtime Routing rules.'));
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

        function reloadRouting(current) {
            setMessage('notice', _('Reloading the saved Routing file...'));

            return callRead().then(function(next) {
                return nftflowUi.requireOk(next, _('Unable to read the Routing file.'));
            }).then(function(next) {
                current.markSaved(next.config || '');
                setMessage('ok', _('Saved Routing file reloaded.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to read the Routing file.')));
                return false;
            });
        }

        function loadDefaultRouting(current) {
            setMessage('notice', _('Loading default Routing template...'));

            return callDefault().then(function(next) {
                return nftflowUi.requireOk(next, _('Unable to read the default Routing template.'));
            }).then(function(next) {
                current.setValue(next.config || '');
                current.focus();
                setMessage('notice', _('Default Routing template loaded in the editor. Review before saving.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to read the default Routing template.')));
                return false;
            });
        }

        function formatRoutingEditor(current) {
            current.setValue(formatRouting(current.getValue()));
            current.focus();
            setMessage('ok', _('Formatted in the editor. Review before saving.'));
            return Promise.resolve(true);
        }

        function saveRouting(current) {
            var value = current.getValue();
            setMessage('notice', _('Saving Routing file...'));

            return callSave(value).then(function(next) {
                return nftflowUi.requireOk(next, _('The Routing file could not be saved.'));
            }).then(function(next) {
                current.markSaved(next.config === undefined ? value : next.config);
                setMessage('ok', _('Routing file saved.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('The Routing file could not be saved.')));
                return false;
            });
        }

        function installRouting(current) {
            if (current.isDirty()) {
                current.focus();
                setMessage('error', _('Save the Routing file before installing it.'));
                return Promise.resolve(false);
            }
            setMessage('notice', _('Installing Routing commands...'));
            return callInstall().then(function(next) {
                return nftflowUi.requireOk(next, _('Routing commands could not be installed.'));
            }).then(function() {
                invalidateRuntime();
                setMessage('ok', _('Routing installed.'));
                return refreshRuntime();
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Routing commands could not be installed.')));
                return false;
            });
        }

        function uninstallRouting() {
            setMessage('notice', _('Uninstalling Routing commands...'));
            return callUninstall().then(function(next) {
                return nftflowUi.requireOk(next, _('Routing commands could not be uninstalled.'));
            }).then(function() {
                invalidateRuntime();
                setMessage('ok', _('Routing uninstalled.'));
                return refreshRuntime();
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Routing commands could not be uninstalled.')));
                return false;
            });
        }

        function toggleRouting(current, installed) {
            return installed ? uninstallRouting() : installRouting(current);
        }

        editor = nftflowEditor.create({
            id: 'nftflow-routing-editor',
            label: _('Policy routing commands'),
            minHeight: '16em',
            rows: 16,
            format: formatRoutingEditor,
            loadDefault: loadDefaultRouting,
            reload: reloadRouting,
            save: saveRouting,
            installToggle: toggleRouting
        });

        if (result && result.ok === true)
            editor.markSaved(result.config || '');
        else
            setMessage('error', nftflowUi.errorMessage(result, _('Unable to read the Routing file.')));

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

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Routing')),
            E('div', { 'class': 'cbi-map-descr' }, _('Edit and save policy routing. Use the editor toggle to install or uninstall it manually. NftFlow automatically installs saved routing when the service starts and removes it when the service stops or exits unexpectedly.')),
            E('div', { 'class': 'cbi-section' }, [
                editor.root,
                message
            ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', { 'class': 'cbi-section-title' }, _('Runtime rules')),
                runtimeToolbar,
                activeEditor.root
            ])
        ]);
    }
});
