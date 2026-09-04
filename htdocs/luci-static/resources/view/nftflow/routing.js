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

var callValidate = rpc.declare({
    object: 'luci.nftflow',
    method: 'routing_validate',
    params: [ 'config' ],
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

var callApply = rpc.declare({
    object: 'luci.nftflow',
    method: 'routing_apply',
    params: [ 'config' ],
    expect: { '': {} },
    reject: true
});

var callDefault = rpc.declare({
    object: 'luci.nftflow.defaults',
    method: 'routing',
    expect: { '': {} },
    reject: true
});

function validationDetail(result) {
    var detail = [ result && result.error, result && result.detail ].filter(Boolean).join(': ');
    var lower = detail.toLowerCase();
    var label = lower.indexOf('rule') >= 0 && lower.indexOf('route') < 0
        ? _('Routing rule error: %s')
        : lower.indexOf('route') >= 0 && lower.indexOf('rule') < 0
            ? _('Routing route error: %s')
            : _('Routing route/rule error: %s');

    return label.format(detail || _('the command was rejected'));
}

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

        function setMessage(state, value) {
            nftflowUi.setState(message, state, value);
        }

        function updateRuntime(next) {
            activeEditor.markSaved(next && next.active
                ? next.active
                : _('# No active policy routing commands are installed.\n'));
            nftflowUi.setState(runtimeState, 'ok', _('Loaded'));
        }

        function refreshRuntime(manual) {
            if (!pageVisible || runtimeRequest)
                return runtimeRequest || Promise.resolve();

            if (manual)
                nftflowUi.setState(runtimeState, 'notice', _('Refreshing...'));

            runtimeRequest = callRead().then(function(next) {
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
                updateRuntime(next);
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
                setMessage('notice', _('Default Routing template loaded in the editor. Review before applying.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to read the default Routing template.')));
                return false;
            });
        }

        function withinLimit(current) {
            if (current.withinLimit())
                return true;

            current.focus();
            setMessage('error', _('The Routing file is larger than 32 KiB.'));
            return false;
        }

        function formatRoutingEditor(current) {
            current.setValue(formatRouting(current.getValue()));
            current.focus();
            setMessage('ok', _('Formatted in the editor. Review before applying.'));
            return Promise.resolve(true);
        }

        function checkRouting(current) {
            if (!withinLimit(current))
                return Promise.resolve(false);

            setMessage('notice', _('Checking Routing commands...'));
            return callValidate(current.getValue()).then(function(next) {
                if (!next || next.valid !== true)
                    throw new Error(validationDetail(next));
                setMessage('ok', _('Routing syntax check passed.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Routing syntax check failed.')));
                return false;
            });
        }

        function applyRouting(current) {
            if (!withinLimit(current))
                return Promise.resolve(false);

            setMessage('notice', _('Applying Routing commands to runtime...'));
            return callApply(current.getValue()).then(function(next) {
                return nftflowUi.requireOk(next, _('Unable to apply Routing commands.'));
            }).then(function(next) {
                updateRuntime(next);
                setMessage('ok', _('Applied to runtime; the saved file was not changed.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to apply Routing commands.')));
                return false;
            });
        }

        function applySaveRouting(current) {
            if (!withinLimit(current))
                return Promise.resolve(false);

            var applied = false;
            var value = current.getValue();
            setMessage('notice', _('Applying Routing commands and saving the file...'));

            return callApply(value).then(function(next) {
                return nftflowUi.requireOk(next, _('Unable to apply Routing commands.'));
            }).then(function(next) {
                applied = true;
                updateRuntime(next);
                return callSave(value);
            }).then(function(next) {
                return nftflowUi.requireOk(next, _('The Routing file could not be saved.'));
            }).then(function(next) {
                current.markSaved(next.config === undefined ? value : next.config);
                setMessage('ok', _('Applied to runtime and saved to the Routing file.'));
                return true;
            }).catch(function(error) {
                var fallback = applied
                    ? _('Applied to runtime, but the Routing file could not be saved.')
                    : _('Unable to apply Routing commands.');
                setMessage('error', nftflowUi.errorMessage(error, fallback));
                return false;
            });
        }

        editor = nftflowEditor.create({
            id: 'nftflow-routing-editor',
            label: _('Policy routing commands'),
            minHeight: '16em',
            rows: 16,
            format: formatRoutingEditor,
            check: checkRouting,
            loadDefault: loadDefaultRouting,
            reload: reloadRouting,
            apply: applyRouting,
            applySave: applySaveRouting
        });

        if (result && result.ok === true) {
            editor.markSaved(result.config || '');
            updateRuntime(result);
        } else {
            setMessage('error', nftflowUi.errorMessage(result, _('Unable to read the Routing file.')));
        }

        var refreshButton = E('button', {
            'class': 'btn cbi-button cbi-button-action',
            'type': 'button'
        }, _('Refresh'));
        refreshButton.addEventListener('click', function() {
            refreshRuntime(true);
        });

        var runtimeToolbar = E('div', {
            'class': 'cbi-section-descr',
            'style': 'display:flex; align-items:center; justify-content:space-between; gap:1em'
        }, [ runtimeState, refreshButton ]);

        window.addEventListener('pagehide', function() {
            pageVisible = false;
        }, { once: true });

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Routing')),
            E('div', { 'class': 'cbi-map-descr' }, _('Edit policy routing commands. Apply changes temporarily or apply and save them permanently.')),
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