# luci-app-nftflow

`luci-app-nftflow` is a LuCI network traffic management plugin for OpenWrt. It manages Xray, nftables transparent proxy rules, policy routing, GeoIP/GeoSite data and component updates.

The backend is implemented with OpenWrt native **ucode**. No Lua runtime or LuCI Lua compatibility libraries are required.

## Install

OpenWrt 25.12+:

```sh
wget -qO- https://raw.githubusercontent.com/madwind/luci-app-nftflow/master/install.sh | sh
```

The installer downloads the latest release manifest, verifies the APK SHA256, updates package indexes and installs or upgrades NftFlow.

## Features

- View service status and start, stop, or restart services
- Edit and validate Xray YAML configuration
- Edit, validate and transactionally apply nftables firewall rules
- Expand `%geoip:<tag>%` macros directly from `geoip.dat`
- Edit and transactionally apply policy routing
- Download, verify and update GeoIP/GeoSite data
- Check and update NftFlow and Xray Core
- Optional weekly automatic update checks

## Runtime requirements

The package targets OpenWrt 25.12+ with LuCI and uses the ucode runtime supplied by `luci-base`.
