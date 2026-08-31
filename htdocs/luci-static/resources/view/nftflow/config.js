'use strict';
'require view';
'require rpc';
'require nftflow.ui as nftflowUi';
'require nftflow.editor as nftflowEditor';

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

function parseConfig(value) {
    var parsed;

    try {
        parsed = JSON.parse(value);
    } catch (error) {
        throw new Error(_('JSON syntax: %s').format(error.message));
    }

    if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object')
        throw new Error(_('The document root must be a JSON object.'));

    return parsed;
}

function resultDetail(result, fallback) {
    var detail = [ result && result.error, result && result.detail ].filter(Boolean).join(': ');
    return detail || fallback;
}

function geodataFallbackDetail(result) {
    var replacements = result && Array.isArray(result.geodata_replacements) ? result.geodata_replacements : [];
    if (!replacements.length)
        return '';

    return replacements.map(function(item) {
        return '%s -> %s'.format(item.from, item.to);
    }).join(', ');
}

return view.extend({
    load: function() {
        return L.resolveDefault(callConfigRead(), { ok: false, error: _('Unable to read the Xray JSON file.') });
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
            setMessage('error', _('The Xray JSON file is larger than 32 KiB.'));
            return false;
        }

        function formatConfig(current) {
            try {
                current.setValue(JSON.stringify(parseConfig(current.getValue()), null, 4) + '\n');
                current.focus();
                setMessage('ok', _('Formatted in the editor. Review before applying.'));
                return Promise.resolve(true);
            } catch (error) {
                current.focus();
                setMessage('error', error.message);
                return Promise.resolve(false);
            }
        }

        function checkConfig(current) {
            if (!withinLimit(current))
                return Promise.resolve(false);

            setMessage('notice', _('Checking Xray configuration...'));
            return callConfigValidate(current.getValue()).then(function(next) {
                if (!next || next.valid !== true)
                    throw new Error(resultDetail(next, _('Xray configuration test failed.')));
                var fallback = geodataFallbackDetail(next);
                if (fallback)
                    setMessage('notice', _('Xray configuration test passed with temporary GeoData fallback: %s').format(fallback));
                else
                    setMessage('ok', _('Xray configuration test passed.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Xray configuration test failed.')));
                return false;
            });
        }

        function reloadConfig(current) {
            setMessage('notice', _('Reloading the saved Xray JSON file...'));
            return callConfigRead().then(function(next) {
                return nftflowUi.requireOk(next, _('Unable to read the Xray JSON file.'));
            }).then(function(next) {
                current.markSaved(next.config === undefined || next.config === null ? '{}\n' : String(next.config));
                setMessage('ok', _('Saved Xray JSON file reloaded.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to read the Xray JSON file.')));
                return false;
            });
        }

        function applyConfig(current) {
            if (!withinLimit(current))
                return Promise.resolve(false);

            setMessage('notice', _('Applying Xray configuration to runtime...'));
            return callConfigApply(current.getValue()).then(function(next) {
                return nftflowUi.requireOk(next, _('Unable to apply the Xray configuration.'));
            }).then(function(next) {
                var fallback = geodataFallbackDetail(next);
                if (fallback)
                    setMessage('notice', _('Applied with temporary GeoData fallback: %s').format(fallback));
                else
                    setMessage('ok', _('Applied to runtime; the saved file was not changed.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to apply the Xray configuration.')));
                return false;
            });
        }

        function applySaveConfig(current) {
            if (!withinLimit(current))
                return Promise.resolve(false);

            var applied = false;
            var appliedResult;
            var value = current.getValue();
            setMessage('notice', _('Applying Xray configuration and saving the file...'));

            return callConfigApply(value).then(function(next) {
                appliedResult = nftflowUi.requireOk(next, _('Unable to apply the Xray configuration.'));
                return appliedResult;
            }).then(function() {
                applied = true;
                return callConfigSave(value);
            }).then(function(next) {
                return nftflowUi.requireOk(next, _('The Xray JSON file could not be saved.'));
            }).then(function(next) {
                current.markSaved(next.config === undefined ? value : next.config);
                var fallback = geodataFallbackDetail(appliedResult);
                if (fallback)
                    setMessage('notice', _('Applied and saved; runtime used temporary GeoData fallback: %s').format(fallback));
                else
                    setMessage('ok', _('Applied to runtime and saved to the Xray JSON file.'));
                return true;
            }).catch(function(error) {
                var fallback = applied
                    ? _('Applied to runtime, but the Xray JSON file could not be saved.')
                    : _('Unable to apply the Xray configuration.');
                setMessage('error', nftflowUi.errorMessage(error, fallback));
                return false;
            });
        }

        editor = nftflowEditor.create({
            id: 'nftflow-config-editor',
            label: _('Xray JSON configuration'),
            minHeight: '30em',
            rows: 30,
            format: formatConfig,
            check: checkConfig,
            reload: reloadConfig,
            apply: applyConfig,
            applySave: applySaveConfig
        });

        if (result && result.ok === true)
            editor.markSaved(result.config === undefined || result.config === null ? '{}\n' : String(result.config));
        else
            setMessage('error', nftflowUi.errorMessage(result, _('Unable to read the Xray JSON file.')));

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Xray Config')),
            E('div', { 'class': 'cbi-map-descr' }, _('Edit the complete Xray JSON configuration. Apply uses a temporary runtime copy; Apply & Save also updates the saved file.')),
            E('div', { 'class': 'cbi-section' }, [
                editor.root,
                message
            ])
        ]);
    }
});
