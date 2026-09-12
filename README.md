# luci-app-nftflow

`luci-app-nftflow` is a LuCI network traffic management plugin for OpenWrt. It provides managed process lifecycle, YAML configuration editing, nftables firewall rules, policy routing, runtime traffic statistics and self-updates.

The backend is implemented with OpenWrt native **ucode**. No Lua runtime or LuCI Lua compatibility libraries are required.

## Install

OpenWrt 25.12+:

```sh
wget -qO- https://raw.githubusercontent.com/madwind/luci-app-nftflow/master/install.sh | sh
```

The installer reads the latest GitHub Release metadata, verifies the APK against the release asset SHA256 digest and installs or upgrades NftFlow.

## Features

- Manage a user-selected runtime executable and command-line arguments
- View runtime status and start, stop or restart the managed process
- Edit and format an optional YAML configuration file
- Read optional runtime traffic counters from a user-configured HTTP/HTTPS JSON endpoint
- Configure dot-separated inbound and outbound JSON object paths for metrics extraction
- Edit, save, install and uninstall nftables firewall rules from the editor
- Substitute `%port%` from `nftflow.main.tproxy_port` and `%gid%` from `nftflow.main.run_gid`
- Optionally expand `%geoip:<tag>%` firewall macros from a user-provided GeoIP database
- Configure optional GeoIP and GeoSite database paths without runtime-specific defaults
- Edit, save, install and uninstall policy routing from the editor
- Start the managed process before installing routing and firewall rules
- Automatically remove firewall and routing rules after the managed process stops or exits unexpectedly
- Check and update NftFlow
- Optional weekly automatic update checks

## Runtime model

NftFlow does not install, select or identify the program it manages. Configure the executable path and add each command-line argument separately in **Settings**. Arguments are passed directly to the executable without shell evaluation.

The YAML configuration file is empty by default. NftFlow can format, save and edit it, but does not interpret or validate runtime-specific semantics. If the selected program needs the YAML path, add that path to its configured arguments.

NftFlow does not bundle or download GeoIP or GeoSite data, and neither path has a runtime-specific default. `geoip_file` is used when `%geoip:<tag>%` appears in a Firewall set and is also exported to the managed process as `NFTFLOW_GEOIP_FILE`. `geosite_file` is exported as `NFTFLOW_GEOSITE_FILE`; NftFlow does not interpret the GeoSite database itself.

Runtime traffic statistics are optional. Configure `metrics_url` to an HTTP or HTTPS endpoint that returns JSON tag counters. `metrics_inbound_path` and `metrics_outbound_path` are dot-separated object paths used to locate the inbound and outbound tag maps in that document and must be configured explicitly. Each tag object must provide cumulative `uplink` and `downlink` byte counters. NftFlow does not discover a runtime-specific endpoint automatically.

Firewall and Routing are part of the NftFlow lifecycle. Startup launches the configured process, removes stale traffic rules, installs Routing and then installs Firewall. Stop and failure cleanup terminate the managed process before removing Firewall and Routing.

## Runtime requirements

The package targets OpenWrt 25.12+ with LuCI and uses the ucode runtime supplied by `luci-base`. Any managed runtime executable and optional data files must be installed and maintained separately by the user.

## License

MIT. See [LICENSE](LICENSE).
