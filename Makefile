include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-nftflow
PKG_VERSION:=$(shell sed -n 's/^NFTFLOW_VERSION=//p' $(CURDIR)/version.env)
PKG_RELEASE:=$(shell sed -n 's/^NFTFLOW_RELEASE=//p' $(CURDIR)/version.env)

LUCI_TITLE:=LuCI support for NftFlow
LUCI_DESCRIPTION:=NftFlow managed runtime, YAML configuration, nftables/routing controls and status UI for OpenWrt 25.12+.
LUCI_EXTRA_DEPENDS:= \
	luci-base (>=0), \
	nftables (>=0), \
	kmod-nft-fib (>=0), \
	kmod-nft-tproxy (>=0), \
	ip (>=0)
LUCI_PKGARCH:=all
LUCI_MAINTAINER:=madwind
LUCI_URL:=https://github.com/madwind/luci-app-nftflow

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

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
upgrade_running='/tmp/nftflow-upgrade.running'

[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	if [ "$$(uci -q get nftflow.main.enabled 2>/dev/null)" = "1" ]; then
		/etc/init.d/nftflow enable >/dev/null 2>&1 || true
		if [ -f "$${upgrade_running}" ]; then
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
	remove_package=0
	case "$${1:-remove}" in
		upgrade)
			rm -f /tmp/nftflow-upgrade.running
			pid="$$(cat /var/run/nftflow/runtime.pid 2>/dev/null)"
			case "$${pid}" in ''|*[!0-9]*) ;; *) kill -0 "$${pid}" >/dev/null 2>&1 && : > /tmp/nftflow-upgrade.running ;; esac
			[ -x /etc/init.d/nftflow ] && /etc/init.d/nftflow stop >/dev/null 2>&1 || true
			;;
		*)
			remove_package=1
			[ -x /etc/init.d/nftflow ] && /etc/init.d/nftflow stop >/dev/null 2>&1 || true
			rm -f /tmp/nftflow-upgrade.running
			;;
	esac
	[ -x /usr/libexec/nftflow/nftflowctl ] && /usr/libexec/nftflow/nftflowctl cleanup >/dev/null 2>&1 || true
	[ "$${remove_package}" = "1" ] && [ -x /etc/init.d/nftflow ] && /etc/init.d/nftflow cleanup_groups >/dev/null 2>&1 || true
}
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
