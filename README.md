# luci-app-nftflow

`luci-app-nftflow` is a LuCI network traffic management plugin for OpenWrt. It provides configuration editing, firewall rule management, policy routing and component updates.

The backend is implemented with OpenWrt native **ucode**. No Lua runtime or LuCI Lua compatibility libraries are required.

## Install

OpenWrt 25.12+:

```sh
wget -qO- https://raw.githubusercontent.com/madwind/luci-app-nftflow/master/install.sh | sh
```

The installer downloads the latest release manifest, verifies the APK SHA256, updates package indexes and installs or upgrades NftFlow.

## Features

- View service status and start, stop, or restart services
- Edit YAML configuration and validate it with Xray before apply
- Edit, validate and transactionally apply nftables firewall rules
- Expand `%geoip:<tag>%` macros directly from `geoip.dat`
- Resolve `%port%` from `nftflow.main.listen_port` in Xray YAML and firewall templates
- Resolve `%gid%` from `nftflow.main.run_gid` in firewall templates
- Edit and transactionally apply policy routing
- Download, verify and update GeoIP/GeoSite data
- Check and update NftFlow and managed components
- Optional weekly automatic update checks

The saved YAML and firewall files retain their placeholders. NftFlow resolves them only in temporary runtime copies before validation or apply, so the Xray listener, TPROXY target, and Xray process GID bypass remain synchronized. If Xray exits unexpectedly, NftFlow removes its interception firewall and policy routing before procd decides whether to restart the service.

## Runtime requirements

The package targets OpenWrt 25.12+ with LuCI and uses the ucode runtime supplied by `luci-base`.
