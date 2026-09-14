# luci-app-nftflow

`luci-app-nftflow` is a LuCI network traffic management plugin for OpenWrt. It provides managed process lifecycle, YAML configuration editing, nftables firewall rules, policy routing and runtime traffic statistics.

The backend is implemented with OpenWrt native **ucode**. No Lua runtime or LuCI Lua compatibility libraries are required.

## Install

OpenWrt 25.12+ uses the signed `madwind/openwrt-packages` APK repository:

```sh
wget -O- https://raw.githubusercontent.com/madwind/openwrt-packages/main/install.sh | sh
apk add luci-app-nftflow
```

After the repository is configured, update package metadata and upgrade NftFlow normally with:

```sh
apk update
apk add --upgrade luci-app-nftflow
```

## Features

- Manage a user-selected runtime command
- View runtime status and start, stop or restart the managed process
- Edit an optional YAML configuration file
- Read optional runtime traffic counters from a user-configured HTTP/HTTPS JSON endpoint
- Configure dot-separated inbound and outbound JSON object paths for metrics extraction
- Edit, save, install and uninstall nftables firewall rules from the editor
- Substitute `%gid%` from `nftflow.main.run_gid`
- Learn direct runtime destinations from socket mark `0x40000000` and bypass them for 24 hours
- Allow UDP/443 only for local, private and learned direct destinations; reject it before proxying
- Edit, save, install and uninstall policy routing from the editor
- Start the managed process before installing routing and firewall rules
- Automatically remove firewall and routing rules after the managed process stops or exits unexpectedly

## Runtime model

NftFlow does not install, select or identify the program it manages. Configure the complete shell command in **Settings**, for example `/usr/bin/example --config /etc/nftflow/config.yaml`. NftFlow starts that command with the configured process GID and open-file limit.

The configured command is intentionally administrator-controlled and is executed as part of the privileged service lifecycle. Write access to the NftFlow UCI configuration therefore grants privileged service-management capability and should only be assigned to trusted administrators.

The YAML configuration file is empty by default. NftFlow can save and edit it, but does not interpret or validate runtime-specific semantics. If the selected program needs the YAML path, include that path in the configured command.

The default Firewall template learns IPv4 and IPv6 destinations from runtime sockets carrying packet mark `0x40000000`. Learned destinations remain in dynamic nftables sets for 24 hours and new connections to them bypass the managed runtime. Direct and proxied connections are pinned with conntrack marks so destination expiry or learning cannot change the path of an existing connection. UDP/443 is accepted only for local, private and learned direct destinations; other UDP/443 traffic is rejected instead of being sent to the managed runtime. Configure the runtime's direct outbound sockets to use `SO_MARK=0x40000000` when this behavior is wanted. The default transparent proxy target port is `12345`; edit the Firewall rules if the managed runtime listens on another port.

Runtime traffic statistics are optional. Configure `metrics_url` to an HTTP or HTTPS endpoint that returns JSON tag counters. `metrics_inbound_path` and `metrics_outbound_path` are dot-separated object paths used to locate the inbound and outbound tag maps in that document and must be configured explicitly. Each tag object must provide cumulative `uplink` and `downlink` byte counters. NftFlow does not discover a runtime-specific endpoint automatically.

Firewall and Routing are part of the NftFlow lifecycle. Startup launches the configured process, removes stale traffic rules, installs Routing and then installs Firewall. Stop and failure cleanup terminate the managed process before removing Firewall and Routing.

## Runtime requirements

The package targets OpenWrt 25.12+ with LuCI and uses the ucode runtime supplied by `luci-base`. Any managed runtime executable and optional data files must be installed and maintained separately by the user.

## License

The package contains MIT-licensed and Apache-2.0-licensed sources. See [LICENSE](LICENSE) and [LICENSE-APACHE](LICENSE-APACHE).
