'use strict';
'require view';
'require form';
'require rpc';
'require uci';
'require nftflow.ui as nftflowUi';

var callAction = rpc.declare({
    object: 'luci.nftflow',
    method: 'action',
    params: [ 'name' ],
    expect: { '': {} },
    reject: true
});

var callServiceSync = rpc.declare({
    object: 'luci.nftflow',
    method: 'service_sync',
    expect: { '': {} },
    reject: true
});

function requiredValue(sectionId, value) {
    return value && value.trim() ? true : _('This field is required.');
}

function addValueOption(section, name, label, description, defaultValue) {
    var option = section.option(form.Value, name, label, description);
    option.rmempty = false;
    option.validate = requiredValue;
    if (defaultValue)
        option.default = defaultValue;
    return option;
}

return view.extend({
    load: function() {
        return uci.load('nftflow');
    },

    render: function() {
        document.title = _('NftFlow | Settings');

        var map = new form.Map('nftflow', _('Settings'), _('Persistent NftFlow service, path, GeoData and process configuration.'));

        var service = map.section(form.NamedSection, 'main', 'nftflow', _('Service'));
        service.anonymous = true;

        var option = service.option(form.Flag, 'enabled', _('Enable service'), _('Start NftFlow automatically when the router boots.'));
        option.rmempty = false;
        option.default = '0';

        option = service.option(form.DummyValue, 'mode', _('Interception mode'), _('The current NftFlow service integration uses TPROXY.'));
        option.cfgvalue = function() { return _('TPROXY'); };

        var paths = map.section(form.NamedSection, 'main', 'nftflow', _('Paths'));
        paths.anonymous = true;

        addValueOption(paths, 'xray_bin', _('Xray binary'), _('Path to the installed Xray executable.'), '/usr/bin/xray');
        addValueOption(paths, 'config_file', _('YAML file'), _('Complete hand-written Xray YAML configuration.'), '/etc/nftflow/config.yaml');
        addValueOption(paths, 'asset_dir', _('Asset directory'), _('Directory containing Xray GeoData assets.'), '/usr/share/xray');

        var geodata = map.section(form.NamedSection, 'main', 'nftflow', _('GeoData'));
        geodata.anonymous = true;

        addValueOption(geodata, 'geoip_file', _('GeoIP file'), _('Local GeoIP dataset path.'), '/usr/share/xray/geoip.dat');
        addValueOption(geodata, 'geosite_file', _('GeoSite file'), _('Local GeoSite dataset path.'), '/usr/share/xray/geosite.dat');
        addValueOption(geodata, 'geoip_url', _('GeoIP URL'), _('HTTPS source used to check and update GeoIP.'), 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat');
        addValueOption(geodata, 'geosite_url', _('GeoSite URL'), _('HTTPS source used to check and update GeoSite.'), 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat');

        var process = map.section(form.NamedSection, 'main', 'nftflow', _('Process'));
        process.anonymous = true;

        option = process.option(form.Value, 'run_gid', _('Process GID'), _('Numeric primary group identity used by the Xray process.'));
        option.datatype = 'uinteger';
        option.rmempty = false;
        option.default = '23333';

        option = process.option(form.Value, 'run_group', _('Process group'), _('Group name associated with the process identity.'));
        option.rmempty = false;
        option.validate = requiredValue;

        option = process.option(form.Value, 'nofile', _('Open-file limit'), _('RLIMIT_NOFILE applied before starting Xray.'));
        option.datatype = 'uinteger';
        option.rmempty = false;

        return map.render();
    },

    handleSaveApply: function(event, mode) {
        if (this._nftflowAppliedHandler)
            document.removeEventListener('uci-applied', this._nftflowAppliedHandler);

        var appliedHandler = function() {
            document.removeEventListener('uci-applied', appliedHandler);

            if (this._nftflowAppliedHandler === appliedHandler)
                this._nftflowAppliedHandler = null;

            return callServiceSync().then(function(result) {
                return nftflowUi.requireOk(result, _('NftFlow boot state synchronization failed.'));
            }).then(function(result) {
                return callAction(result.enabled ? 'start' : 'stop');
            }).then(function(result) {
                return nftflowUi.requireOk(result, _('NftFlow service state reconciliation failed.'));
            }).then(function() {
                return true;
            }).catch(function(error) {
                nftflowUi.notifyFatal(error, _('NftFlow service state reconciliation failed.'));
                return false;
            });
        }.bind(this);

        this._nftflowAppliedHandler = appliedHandler;
        document.addEventListener('uci-applied', appliedHandler);
        return this.super('handleSaveApply', [ event, mode ]);
    }
});
