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

var callConfigApply = rpc.declare({
    object: 'luci.nftflow',
    method: 'config_apply',
    params: [ 'config' ],
    expect: { '': {} },
    reject: true
});

return view.extend({
    load: function() {
        return Promise.all([
            L.resolveDefault(callConfigRead(), { ok: false, error: _('Unable to read the YAML configuration file.') })
        ]);
    },

    render: function(data) {
        document.title = _('NftFlow | Configuration');

        var result = data && data[0] || {};
        var message = E('div', { 'class': 'cbi-section-descr', 'aria-live': 'polite' });
        var pathText = E('code', {}, result.path || '—');
        var editor;

        function setMessage(state, value) {
            nftflowUi.setState(message, state, value);
        }

        function formatConfig(current) {
            var value = current.getValue();
            var formatted = nftflowYamlFormat.format(value);

            current.focus();
            if (formatted === value) {
                setMessage('notice', _('YAML is already formatted.'));
                return Promise.resolve(false);
            }

            current.setValue(formatted);
            setMessage('ok', _('YAML formatted in the editor. Review before saving and applying.'));
            return Promise.resolve(true);
        }

        function reloadConfig(current) {
            setMessage('notice', _('Reloading the saved YAML configuration...'));
            return callConfigRead().then(function(next) {
                return nftflowUi.requireOk(next, _('Unable to read the YAML configuration file.'));
            }).then(function(next) {
                current.markSaved(next.config === undefined || next.config === null ? '' : String(next.config));
                nftflowUi.setText(pathText, next.path || '—');
                setMessage('ok', _('Saved YAML configuration reloaded.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, _('Unable to read the YAML configuration file.')));
                return false;
            });
        }

        function saveApplyConfig(current) {
            var value = current.getValue();
            var saved = false;
            setMessage('notice', _('Saving YAML configuration...'));

            return callConfigApply(value).then(function(next) {
                if (next && next.saved === true) {
                    saved = true;
                    current.markSaved(next.config === undefined ? value : next.config);
                    nftflowUi.setText(pathText, next.path || '—');
                }
                return nftflowUi.requireOk(next, _('Unable to save and apply the YAML configuration.'));
            }).then(function(next) {
                if (!saved)
                    current.markSaved(next.config === undefined ? value : next.config);
                setMessage(next.applied === false ? 'notice' : 'ok', next.applied === false
                    ? _('YAML configuration saved. NftFlow is stopped, so the runtime process was not restarted.')
                    : _('YAML configuration saved and the runtime process was restarted.'));
                return true;
            }).catch(function(error) {
                setMessage('error', nftflowUi.errorMessage(error, saved
                    ? _('The YAML configuration was saved, but the runtime process could not be restarted.')
                    : _('Unable to save the YAML configuration.')));
                return false;
            });
        }

        editor = nftflowEditor.create({
            id: 'nftflow-config-editor',
            label: _('YAML configuration'),
            minHeight: '32em',
            rows: 32,
            format: formatConfig,
            formatLabel: _('Format YAML'),
            reload: reloadConfig,
            saveApply: saveApplyConfig
        });

        if (result.ok === true)
            editor.markSaved(result.config === undefined || result.config === null ? '' : String(result.config));
        else
            setMessage('error', nftflowUi.errorMessage(result, _('Unable to read the YAML configuration file.')));

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', { 'class': 'cbi-map-title', 'name': 'content' }, _('Configuration')),
            E('div', { 'class': 'cbi-map-descr' }, [
                _('Edit the YAML file managed by NftFlow. NftFlow only formats and saves this file; the selected runtime program decides how to interpret it. Current file: '),
                pathText
            ]),
            E('div', { 'class': 'cbi-section' }, [ editor.root, message ])
        ]);
    }
});
