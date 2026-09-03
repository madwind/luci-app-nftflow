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

var callGeoStatus = rpc.declare({
    object: 'luci.nftflow',
    method: 'geo_status',
    expect: { '': {} },
    reject: true
});

function resultDetail(result, fallback) {
    var detail = [ result && result.error, result && result.detail ].filter(Boolean).join(': ');
    return detail || fallback;
}

function usesGeoKind(config, kind) {
    return new RegExp('(^|[^A-Za-z0-9_-])' + kind + ':', 'm').test(String(config || ''));
}

return view.extend({
    load: function() {
        return Promise.all([
            L.resolveDefault(callConfigRead(), { ok: false, error: _('Unable to read the Xray YAML file.') }),
            L.resolveDefault(callGeoStatus(), { ok: false, error: _('Unable to read GeoData status.') })
        ]);
    },

    render: function(data) {
        document.title = _('NftFlow | Xray Config');

        var result = data && data[0];
        var geoResult = data && data[1];
        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var geoMessage = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var editor;

        function setMessage(state, value) {
            nftflowUi.setState(message, state, value);
        }

        function geoAsset(kind) {
            return geoResult && geoResult.ok === true && geoResult.assets ? geoResult.assets[kind] : null;
        }

        function geoPath(kind, asset) {
            if (asset && asset.path) return asset.path;
            return kind === 'geoip' ? '/usr/share/xray/geoip.dat' : '/usr/share/xray/geosite.dat';
        }

        function updateGeoWarning(current) {
            var value = current.getValue();
            var warnings = [];
            var usesGeoip = usesGeoKind(value, 'geoip');
            var usesGeosite = usesGeoKind(value, 'geosite');

            if (!usesGeoip && !usesGeosite) {
                nftflowUi.setState(geoMessage, '', '');
                return;
            }

            if (!geoResult || geoResult.ok !== true) {
                nftflowUi.setState(geoMessage, 'warn', _('This configuration references GeoData, but NftFlow could not verify the installed GeoData files. Check the Updates page before applying.'));
                return;
            }

            if (usesGeoip) {
                var geoip = geoAsset('geoip');
                if (!geoip || geoip.ready !== true) {
                    warnings.push(_('GeoIP is missing or incomplete. NftFlow may install a minimal geoip:private seed as %s when no GeoIP file exists; that seed does not provide entries such as geoip:cn. Updating GeoData downloads the complete GeoIP database and atomically replaces %s. Until then, Xray validation or apply may fail for GeoIP references.').format(
                        geoPath('geoip', geoip), geoPath('geoip', geoip)
                    ));
                }
            }

            if (usesGeosite) {
                var geosite = geoAsset('geosite');
                if (!geosite || geosite.ready !== true) {
                    warnings.push(_('GeoSite is missing or incomplete. NftFlow has no built-in GeoSite fallback. Updating GeoData downloads the complete GeoSite database and atomically installs or replaces %s. Until then, Xray validation or apply may fail for GeoSite references.').format(
                        geoPath('geosite', geosite)
                    ));
                }
            }

            if (warnings.length)
                nftflowUi.setState(geoMessage, 'warn', warnings.join(' '));
            else
                nftflowUi.setState(geoMessage, 'ok', _('GeoData referenced by this configuration is installed.'));
        }

        function withinLimit(current) {
            if (current.withinLimit())
                return true;

            current.focus();
            setMessage('error', _('The Xray YAML file is larger than 32 KiB.'));
            return false;
        }

        function formatConfig(current) {
            var value = current.getValue();
            var formatted = nftflowYamlFormat.format(value);

            updateGeoWarning(current);
            current.focus();

            if (formatted === value) {
                setMessage('notice', _('YAML is already formatted.'));
                return Promise.resolve(false);
            }

            current.setValue(formatted);
            updateGeoWarning(current);
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
                updateGeoWarning(current);
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
                current.setValue(nftflowYamlFormat.format(next.config || ''));
                updateGeoWarning(current);
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
            formatLabel: _('Format YAML'),
            check: checkConfig,
            loadDefault: loadDefaultConfig,
            reload: reloadConfig,
            apply: applyConfig,
            applySave: applySaveConfig,
            onInput: updateGeoWarning
        });

        if (result && result.ok === true)
            editor.markSaved(result.config === undefined || result.config === null ? '' : String(result.config));
        else
            setMessage('error', nftflowUi.errorMessage(result, _('Unable to read the Xray YAML file.')));

        updateGeoWarning(editor);

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Xray Config')),
            E('div', { 'class': 'cbi-map-descr' }, _('Edit the complete Xray YAML configuration. Apply uses a temporary runtime copy; Apply & Save also updates the saved YAML file.')),
            E('div', { 'class': 'cbi-section' }, [
                geoMessage,
                editor.root,
                message
            ])
        ]);
    }
});
