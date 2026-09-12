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

var callStatus = rpc.declare({
    object: 'luci.nftflow',
    method: 'status',
    expect: { '': {} },
    reject: true
});

return view.extend({
    load: function() {
        return uci.load('nftflow');
    },

    render: function() {
        document.title = _('NftFlow | Settings');

        var map = new form.Map('nftflow', _('Settings'), _('Configure the managed runtime process and values used by NftFlow traffic rules.'));

        var service = map.section(form.NamedSection, 'main', 'nftflow', _('Service'));
        service.anonymous = true;

        var option = service.option(form.Flag, 'enabled', _('Enable service'), _('Start NftFlow automatically when the router boots.'));
        option.rmempty = false;
        option.default = '0';

        var process = map.section(form.NamedSection, 'main', 'nftflow', _('Runtime process'));
        process.anonymous = true;

        option = process.option(form.Value, 'command', _('Executable'), _('Absolute path to the program managed by NftFlow. NftFlow does not install or identify this program.'));
        option.placeholder = '/usr/bin/example';
        option.rmempty = true;
        option.validate = function(section_id, value) {
            if (!value)
                return true;
            return value.charAt(0) === '/' ? true : _('Executable must be an absolute path.');
        };

        option = process.option(form.DynamicList, 'argument', _('Arguments'), _('Command-line arguments passed to the executable. Add one argument per row; values are passed directly without shell evaluation.'));
        option.rmempty = true;

        option = process.option(form.Value, 'config_file', _('Managed YAML file'), _('YAML file edited by the Configuration page. Add this path to Arguments yourself when the runtime program needs it.'));
        option.rmempty = false;
        option.default = '/etc/nftflow/config.yaml';
        option.validate = function(section_id, value) {
            if (!/^\/etc\/nftflow\/[A-Za-z0-9._\/-]+$/.test(value || '') || /\/\.\.(?:\/|$)/.test(value || ''))
                return _('Configuration file must be below /etc/nftflow.');
            return true;
        };

        var metrics = map.section(form.NamedSection, 'main', 'nftflow', _('Metrics'));
        metrics.anonymous = true;

        option = metrics.option(form.Value, 'metrics_url', _('Metrics URL'), _('Optional HTTP or HTTPS endpoint used by the Overview page to read runtime traffic counters. Leave empty to disable traffic statistics.'));
        option.placeholder = 'http://127.0.0.1:8080/stats';
        option.rmempty = true;
        option.validate = function(section_id, value) {
            if (!value)
                return true;
            return value.indexOf('http://') === 0 || value.indexOf('https://') === 0
                ? true
                : _('Metrics URL must use HTTP or HTTPS.');
        };

        option = metrics.option(form.Value, 'metrics_inbound_path', _('Inbound JSON path'), _('Dot-separated object path containing inbound counters keyed by tag. Each tag must provide uplink and downlink values.'));
        option.rmempty = true;
        option.validate = function(section_id, value) {
            if (!value)
                return true;
            if (value.charAt(0) === '.' || value.charAt(value.length - 1) === '.' || value.indexOf('..') !== -1)
                return _('Inbound JSON path must be a dot-separated object path.');
            return true;
        };

        option = metrics.option(form.Value, 'metrics_outbound_path', _('Outbound JSON path'), _('Dot-separated object path containing outbound counters keyed by tag. Each tag must provide uplink and downlink values.'));
        option.rmempty = true;
        option.validate = function(section_id, value) {
            if (!value)
                return true;
            if (value.charAt(0) === '.' || value.charAt(value.length - 1) === '.' || value.indexOf('..') !== -1)
                return _('Outbound JSON path must be a dot-separated object path.');
            return true;
        };

        var traffic = map.section(form.NamedSection, 'main', 'nftflow', _('Traffic rules'));
        traffic.anonymous = true;

        option = traffic.option(form.Value, 'run_gid', _('Process GID'), _('Numeric primary group identity used by the runtime process and the %gid% Firewall placeholder.'));
        option.datatype = 'uinteger';
        option.rmempty = false;
        option.default = '23333';

        option = traffic.option(form.Value, 'geoip_file', _('GeoIP database'), _('Optional absolute path used to expand %geoip:<tag>% Firewall macros and exported to the managed process as NFTFLOW_GEOIP_FILE. NftFlow does not download or provide this database.'));
        option.rmempty = true;
        option.validate = function(section_id, value) {
            if (!value)
                return true;
            return value.charAt(0) === '/' ? true : _('GeoIP database path must be absolute.');
        };

        option = traffic.option(form.Value, 'geosite_file', _('GeoSite database'), _('Optional absolute path exported to the managed process as NFTFLOW_GEOSITE_FILE. NftFlow does not download, provide or interpret this database.'));
        option.rmempty = true;
        option.validate = function(section_id, value) {
            if (!value)
                return true;
            return value.charAt(0) === '/' ? true : _('GeoSite database path must be absolute.');
        };

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
                if (!result.enabled)
                    return callAction('stop');

                return callStatus().then(function(status) {
                    status = nftflowUi.requireOk(status, _('Unable to read NftFlow service status.'));
                    return callAction(status.running === true ? 'restart' : 'start');
                });
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