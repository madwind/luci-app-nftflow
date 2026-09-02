'use strict';
'require view';
'require rpc';
'require nftflow.ui as nftflowUi';
'require nftflow.editor as nftflowEditor';
'require nftflow.yamlformat as nftflowYamlFormat';

var callConfigRead = rpc.declare({
    object: 'luci.nftflow',
    method: 'config_read',
    expect: { '': {} },
    reject: true
});

var callConfigValidate = rpc.declare({
    object: 'luci.nftflow',
    method: 'config_validate',
    params: [ 'config' ],
    expect: { '': {} },
    reject: true
});

var callConfigApply = rpc.declare({
    object: 'luci.nftflow',
    method: 'config_apply',
    params: [ 'config' ],
    expect: { '': {} },
    reject: true
});

var callConfigSave = rpc.declare({
    object: 'luci.nftflow',
    method: 'config_save',
    params: [ 'config' ],
    expect: { '': {} },
    reject: true
});

var callConfigDefault = rpc.declare({
    object: 'luci.nftflow.defaults',
    method: 'config',
    expect: { '': {} },
    reject: true
});

function resultDetail(result, fallback) {
    var detail = [ result && result.error, result && result.detail ].filter(Boolean).join(': ');
    return detail || fallback;
}

return view.extend({
    load: function() {
        return L.resolveDefault(callConfigRead(), { ok: false, error: _('Unable to read the Xray YAML file.') });
    },

    render: function(result) {
        document.title = _('NftFlow | Xray Config');

        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var editor;

        function setMessage(state, value) {
            nftflowUi.setState(message, state, value);
        }

        function withinLimit(current) {
            if (current.withinLimit())
                return true;

            current.focus();
            setMessage('error', _('The Xray YAML file is larger than 32 KiB.'));
            return false;
        }

        function formatConfig(current) {
            current.setValue(nftflowYamlFormat.format(current.getValue()));
            current.focus();
            setMessage('ok', _('YAML formatted in the editor. Review before applying.'));
            return Promise.resolve(true);
        }

        function checkConfig(current) {
            if (!withinLimit(current))
                return Promise.resolve(false);

            setMessage('notice', _('Checking Xray YAML configuration...'));
            return callConfigValidate(current.getValue()).then(function(next) {
                if (!next || next.valid !== true)
                    throw new Error(resultDetail(next, _('Xray YAML configuration test failed.')));
                setMessage('ok', _('Xray YAML configuration test passed.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Xray YAML configuration test failed.')));
                return false;
            });
        }

        function reloadConfig(current) {
            setMessage('notice', _('Reloading the saved Xray YAML file...'));
            return callConfigRead().then(function(next) {
                return nftflowUi.requireOk(next, _('Unable to read the Xray YAML file.'));
            }).then(function(next) {
                current.markSaved(next.config === undefined || next.config === null ? '' : String(next.config));
                setMessage('ok', _('Saved Xray YAML file reloaded.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to read the Xray YAML file.')));
                return false;
            });
        }

        function loadDefaultConfig(current) {
            setMessage('notice', _('Loading default Xray YAML template...'));
            return callConfigDefault().then(function(next) {
                return nftflowUi.requireOk(next, _('Unable to read the default Xray YAML template.'));
            }).then(function(next) {
                current.setValue(next.config || '');
                current.focus();
                setMessage('notice', _('Default Xray YAML template loaded in the editor. Review before applying.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to read the default Xray YAML template.')));
                return false;
            });
        }

        function applyConfig(current) {
            if (!withinLimit(current))
                return Promise.resolve(false);

            setMessage('notice', _('Applying Xray YAML configuration to runtime...'));
            return callConfigApply(current.getValue()).then(function(next) {
                return nftflowUi.requireOk(next, _('Unable to apply the Xray YAML configuration.'));
            }).then(function() {
                setMessage('ok', _('Applied to runtime; the saved YAML file was not changed.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to apply the Xray YAML configuration.')));
                return false;
            });
        }

        function applySaveConfig(current) {
            if (!withinLimit(current))
                return Promise.resolve(false);

            var applied = false;
            var value = current.getValue();
            setMessage('notice', _('Applying Xray YAML configuration and saving the file...'));

            return callConfigApply(value).then(function(next) {
                return nftflowUi.requireOk(next, _('Unable to apply the Xray YAML configuration.'));
            }).then(function() {
                applied = true;
                return callConfigSave(value);
            }).then(function(next) {
                return nftflowUi.requireOk(next, _('The Xray YAML file could not be saved.'));
            }).then(function(next) {
                current.markSaved(next.config === undefined ? value : next.config);
                setMessage('ok', _('Applied to runtime and saved to the Xray YAML file.'));
                return true;
            }).catch(function(error) {
                var fallback = applied
                    ? _('Applied to runtime, but the Xray YAML file could not be saved.')
                    : _('Unable to apply the Xray YAML configuration.');
                setMessage('error', nftflowUi.errorMessage(error, fallback));
                return false;
            });
        }

        editor = nftflowEditor.create({
            id: 'nftflow-config-editor',
            label: _('Xray YAML configuration'),
            minHeight: '30em',
            rows: 30,
            format: formatConfig,
            check: checkConfig,
            loadDefault: loadDefaultConfig,
            reload: reloadConfig,
            apply: applyConfig,
            applySave: applySaveConfig
        });

        if (result && result.ok === true)
            editor.markSaved(result.config === undefined || result.config === null ? '' : String(result.config));
        else
            setMessage('error', nftflowUi.errorMessage(result, _('Unable to read the Xray YAML file.')));

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Xray Config')),
            E('div', { 'class': 'cbi-map-descr' }, _('Edit the complete Xray YAML configuration. Apply uses a temporary runtime copy; Apply & Save also updates the saved YAML file.')),
            E('div', { 'class': 'cbi-section' }, [
                editor.root,
                message
            ])
        ]);
    }
});
