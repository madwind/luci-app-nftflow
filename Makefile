include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-nftflow
PKG_VERSION:=$(shell sed -n 's/^VERSION=//p' $(CURDIR)/version.env)
PKG_RELEASE:=$(shell sed -n 's/^RELEASE=//p' $(CURDIR)/version.env)

LUCI_TITLE:=LuCI support for NftFlow
LUCI_DESCRIPTION:=NftFlow transparent proxy lifecycle, YAML config, nftables/routing controls, GeoData updates and status UI for OpenWrt 25.12+.
LUCI_DEPENDS:=@USE_APK
LUCI_EXTRA_DEPENDS:= \
	luci-base (>=0), \
	nftables (>=0), \
	kmod-nft-fib (>=0), \
	kmod-nft-tproxy (>=0), \
	ip (>=0), \
	ucode (>=0), \
	uclient-fetch (>=0), \
	xray-core (>=0)
LUCI_PKGARCH:=all

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=madwind

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-nftflow/conffiles
/etc/config/nftflow
/etc/nftflow/config.yaml
/etc/nftflow/firewall.nft
/etc/nftflow/routing.conf
endef

define Package/luci-app-nftflow/postinst
#!/bin/sh
postinst_root="$${IPKG_INSTROOT}"
version_cache="$${postinst_root}/usr/share/nftflow/installed-version"
upgrade_running='/tmp/nftflow-upgrade.running'

mkdir -p "$${postinst_root}/usr/share/nftflow" || exit 1
printf '%s\n' '$(PKG_VERSION)-r$(PKG_RELEASE)' >"$${version_cache}" || exit 1
chmod 0644 "$${version_cache}" 2>/dev/null || true
chmod 0755 \
	"$${postinst_root}/etc/init.d/nftflow" \
	"$${postinst_root}/usr/libexec/nftflow/config.uc" \
	"$${postinst_root}/usr/libexec/nftflow/firewall-template.uc" \
	"$${postinst_root}/usr/libexec/nftflow/firewall.uc" \
	"$${postinst_root}/usr/libexec/nftflow/geodata-import.uc" \
	"$${postinst_root}/usr/libexec/nftflow/nftflowctl" \
	"$${postinst_root}/usr/libexec/nftflow/routing.uc" \
	"$${postinst_root}/usr/libexec/nftflow/rpc.uc" \
	"$${postinst_root}/usr/libexec/nftflow/runtime.uc" \
	"$${postinst_root}/usr/libexec/nftflow/update-auto.sh" \
	"$${postinst_root}/usr/libexec/nftflow/update.uc" 2>/dev/null || true
chmod 0644 "$${postinst_root}/usr/share/rpcd/ucode/"luci.nftflow*.uc 2>/dev/null || true

[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	/usr/bin/ucode /usr/libexec/nftflow/update.uc auto-sync >/dev/null 2>&1 || logger -t nftflow "cannot synchronize automatic update check schedule"
	if [ "$$(uci -q get nftflow.main.enabled 2>/dev/null)" = "1" ]; then
		/etc/init.d/nftflow enable >/dev/null 2>&1 || true
		if [ "$${NFTFLOW_DEFER_RESTART:-0}" != "1" ] && [ -f "$${upgrade_running}" ]; then
			/etc/init.d/nftflow start >/dev/null 2>&1 || logger -t nftflow "service restart after package upgrade failed"
		fi
	else
		/etc/init.d/nftflow disable >/dev/null 2>&1 || true
	fi
	rm -f "$${upgrade_running}"
	exit 0
}
exit 0
endef

define Package/luci-app-nftflow/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	case "$${1:-remove}" in
		upgrade)
			rm -f /tmp/nftflow-upgrade.running
			pid="$$(cat /var/run/nftflow/xray.pid 2>/dev/null)"
			case "$${pid}" in ''|*[!0-9]*) ;; *) kill -0 "$${pid}" >/dev/null 2>&1 && : > /tmp/nftflow-upgrade.running ;; esac
			[ -x /etc/init.d/nftflow ] && /etc/init.d/nftflow stop >/dev/null 2>&1 || true
			;;
		*)
			[ -x /usr/libexec/nftflow/update-auto.sh ] && /usr/libexec/nftflow/update-auto.sh remove >/dev/null 2>&1 || true
			[ -x /etc/init.d/nftflow ] && /etc/init.d/nftflow stop >/dev/null 2>&1 || true
			rm -f /usr/share/nftflow/installed-version /tmp/nftflow-upgrade.running
			;;
	esac
	[ -x /usr/libexec/nftflow/nftflowctl ] && /usr/libexec/nftflow/nftflowctl cleanup >/dev/null 2>&1 || true
}
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
