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

        var map = new form.Map('nftflow', _('Settings'), _('Configure the managed runtime process and optional traffic statistics.'));

        var service = map.section(form.NamedSection, 'main', 'nftflow', _('Service'));
        service.anonymous = true;

        var option = service.option(form.Flag, 'enabled', _('Enable service'), _('Start NftFlow automatically when the router boots.'));
        option.rmempty = false;
        option.default = '0';

        var process = map.section(form.NamedSection, 'main', 'nftflow', _('Runtime process'));
        process.anonymous = true;

        option = process.option(form.Value, 'command', _('Command'), _('Shell command used to start the runtime process.'));
        option.placeholder = '/usr/bin/example --config /etc/nftflow/config.yaml';
        option.rmempty = true;

        option = process.option(form.Value, 'config_file', _('Managed YAML file'), _('YAML file edited by the Configuration page. Include this path in Command when the runtime program needs it.'));
        option.rmempty = false;
        option.default = '/etc/nftflow/config.yaml';
        option.validate = function(section_id, value) {
            if (!/^\/etc\/nftflow\/[A-Za-z0-9._\/-]+$/.test(value || '') || /\/\.\.(?:\/|$)/.test(value || ''))
                return _('Configuration file must be below /etc/nftflow.');
            return true;
        };

        option = process.option(form.Value, 'run_gid', _('Process GID'), _('Numeric primary group identity applied to the runtime process and used by the %gid% Firewall placeholder.'));
        option.datatype = 'uinteger';
        option.rmempty = false;
        option.default = '23333';

        option = process.option(form.Value, 'nofile', _('Open files limit'), _('Soft and hard RLIMIT_NOFILE applied to the runtime process by procd.'));
        option.datatype = 'uinteger';
        option.rmempty = false;
        option.default = '65536';

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
