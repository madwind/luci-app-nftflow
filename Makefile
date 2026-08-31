# SPDX-License-Identifier: Apache-2.0
#
# luci-app-nftflow - dependency-free hand-written Xray JSON editor for OpenWrt.

NFTFLOW_SOURCE_DIR:=$(dir $(abspath $(lastword $(MAKEFILE_LIST))))

include $(TOPDIR)/rules.mk
include $(NFTFLOW_SOURCE_DIR)version.env

PKG_VERSION:=$(VERSION)
PKG_RELEASE:=$(RELEASE)

LUCI_TITLE:=NftFlow
LUCI_DESCRIPTION:=NftFlow LuCI manager for Xray service, firewall, routing and GeoData.
LUCI_DEPENDS:= \
    +@BUSYBOX_CONFIG_IP \
    +@BUSYBOX_CONFIG_FEATURE_IP_ROUTE \
    +@BUSYBOX_CONFIG_FEATURE_IP_RULE
LUCI_EXTRA_DEPENDS:= \
    luci-base (>=0), \
    nftables (>=0), \
    kmod-nft-bridge (>=0), \
    kmod-nft-fib (>=0), \
    kmod-nft-tproxy (>=0), \
    lua (>=0), \
    luci-lib-jsonc (>=0), \
    luci-lib-nixio (>=0), \
    uclient-fetch (>=0), \
    xray-core (>=0)
LUCI_PKGARCH:=all

PKG_LICENSE:=Apache-2.0
LUCI_MAINTAINER:=NftFlow contributors

define Build/Prepare/luci-app-nftflow
	$(STAGING_DIR_HOSTPKG)/bin/lua \
		$(NFTFLOW_SOURCE_DIR)tools/generate-bootstrap-geodata.lua \
		$(PKG_BUILD_DIR)/root/etc/nftflow/config.json \
		$(PKG_BUILD_DIR)/root/usr/share/nftflow/geoip-private.dat \
		$(PKG_BUILD_DIR)/root/usr/share/nftflow/geoip-bootstrap.dat \
		$(PKG_BUILD_DIR)/root/usr/share/nftflow/geosite-bootstrap.dat
	rm -f $(PKG_BUILD_DIR)/root/usr/share/nftflow/geoip-private.dat
endef

define Package/luci-app-nftflow/conffiles
/etc/config/nftflow
/etc/nftflow/config.json
/etc/nftflow/firewall.nft
/etc/nftflow/routing.conf
endef

define Package/luci-app-nftflow/postinst
#!/bin/sh
postinst_root="$${IPKG_INSTROOT}"
geoip_seed="$${postinst_root}/usr/share/nftflow/geoip-bootstrap.dat"
geosite_seed="$${postinst_root}/usr/share/nftflow/geosite-bootstrap.dat"
geoip_target="$${postinst_root}/usr/share/xray/geoip.dat"
geosite_target="$${postinst_root}/usr/share/xray/geosite.dat"

chmod 0755 "$${postinst_root}/etc/init.d/nftflow" "$${postinst_root}/usr/libexec/nftflow/nftflowctl" 2>/dev/null || true
rm -f "$${postinst_root}/usr/share/nftables.d/table-pre/30-nftflow.nft"
chmod 0644 \
	"$${postinst_root}/usr/share/rpcd/ucode/luci.nftflow.uc" \
	"$${postinst_root}/usr/share/rpcd/acl.d/luci-app-nftflow.json" \
	"$${postinst_root}/usr/share/luci/menu.d/luci-app-nftflow.json" \
	"$${postinst_root}/etc/config/nftflow" \
	"$${postinst_root}/www/luci-static/resources/view/nftflow/"*.js 2>/dev/null || true
[ -f "$${postinst_root}/etc/nftflow/config.json" ] && chmod 0600 "$${postinst_root}/etc/nftflow/config.json" 2>/dev/null || true
[ -f "$${postinst_root}/etc/nftflow/firewall.nft" ] && chmod 0600 "$${postinst_root}/etc/nftflow/firewall.nft" 2>/dev/null || true
[ -f "$${postinst_root}/etc/nftflow/routing.conf" ] && chmod 0600 "$${postinst_root}/etc/nftflow/routing.conf" 2>/dev/null || true

# The APK ships build-time generated bootstrap GeoData matching every geoip:/
# geosite: code referenced by the packaged default config. Install it only when
# the runtime asset is absent, so later full GeoData downloads and package
# upgrades never overwrite complete user-managed databases.
if [ ! -s "$${geoip_target}" ] && [ -f "$${geoip_seed}" ]; then
	mkdir -p "$${postinst_root}/usr/share/xray" || exit 1
	cp "$${geoip_seed}" "$${geoip_target}" || exit 1
	chmod 0644 "$${geoip_target}" 2>/dev/null || true
fi
if [ ! -s "$${geosite_target}" ] && [ -f "$${geosite_seed}" ]; then
	mkdir -p "$${postinst_root}/usr/share/xray" || exit 1
	cp "$${geosite_seed}" "$${geosite_target}" || exit 1
	chmod 0644 "$${geosite_target}" 2>/dev/null || true
fi

[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* /tmp/luci-modulecache /tmp/luci-modulecache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	/etc/init.d/nftflow geodata_schedule >/dev/null 2>&1 || logger -t nftflow "cannot install weekly GeoData update schedule"
	if [ "$$(uci -q get nftflow.main.enabled 2>/dev/null)" = "1" ]; then
		/etc/init.d/nftflow enable >/dev/null 2>&1 || true
		/etc/init.d/nftflow start >/dev/null 2>&1 || logger -t nftflow "service restart after package upgrade failed"
	else
		/etc/init.d/nftflow disable >/dev/null 2>&1 || true
	fi
}
exit 0
endef

define Package/luci-app-nftflow/prerm
#!/bin/sh
# Stop and clean runtime state while the control script and init script still
# exist.  Removal also disables the service and removes its GeoData cron entry;
# an upgrade keeps both persistent service settings and the cron schedule.
[ -n "$${IPKG_INSTROOT}" ] || {
    case "$${1:-remove}" in
        upgrade)
            [ -x /etc/init.d/nftflow ] && /etc/init.d/nftflow stop >/dev/null 2>&1 || true
            [ -x /usr/libexec/nftflow/nftflowctl ] && /usr/libexec/nftflow/nftflowctl cleanup >/dev/null 2>&1 || true
            ;;
        *)
            [ -x /etc/init.d/nftflow ] && /etc/init.d/nftflow uninstall >/dev/null 2>&1 || true
            ;;
    esac
}
exit 0
endef

LUCI_MK:=$(TOPDIR)/feeds/luci/luci.mk
ifeq ($(wildcard $(LUCI_MK)),)
LUCI_MK:=$(TOPDIR)/luci.mk
endif
include $(LUCI_MK)

# call BuildPackage - OpenWrt buildroot signature
