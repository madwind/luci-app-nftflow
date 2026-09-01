#!/bin/sh

. /usr/share/libubox/jshn.sh

CRONTAB=/etc/crontabs/root
TAG=nftflow-geodata-weekly
LEGACY_MONTHLY=nftflow-geodata-monthly
SMART=/usr/libexec/nftflow/geo-smart-update.lua
LOG=/var/log/nftflow/geo-auto-update.log

flag() {
    local value
    value="$(uci -q get "nftflow.main.${1}_auto_update" 2>/dev/null || true)"
    [ "$value" = '1' ] && printf '1' || printf '0'
}

reload_cron() {
    if pidof crond >/dev/null 2>&1; then
        /etc/init.d/cron reload >/dev/null 2>&1 || /etc/init.d/cron restart >/dev/null 2>&1 || true
    fi
}

remove_schedule() {
    [ -f "$CRONTAB" ] || return 0
    sed -i -e "/$TAG/d" -e "/$LEGACY_MONTHLY/d" "$CRONTAB" || return 1
    reload_cron
}

sync_schedule() {
    local geoip geosite
    geoip="$(flag geoip)"
    geosite="$(flag geosite)"
    mkdir -p /etc/crontabs /var/log/nftflow || return 1
    touch "$CRONTAB" || return 1
    sed -i -e "/$TAG/d" -e "/$LEGACY_MONTHLY/d" "$CRONTAB" || return 1
    if [ "$geoip" = '1' ] || [ "$geosite" = '1' ]; then
        printf '%s\n' "17 4 * * 0 /usr/bin/lua $SMART auto >>$LOG 2>&1 # $TAG" >>"$CRONTAB" || return 1
    fi
    reload_cron
}

emit_status() {
    json_init
    json_add_boolean ok 1
    json_add_boolean geoip "$(flag geoip)"
    json_add_boolean geosite "$(flag geosite)"
    json_dump
}

set_auto() {
    local kind="$1" enabled="$2"
    case "$kind" in geoip|geosite) ;; *) return 2;; esac
    case "$enabled" in 1|true|yes|on) enabled=1;; 0|false|no|off|'') enabled=0;; *) return 2;; esac
    uci -q set "nftflow.main.${kind}_auto_update=$enabled" || return 1
    uci -q commit nftflow || return 1
    sync_schedule || return 1
    emit_status
}

case "${1:-}" in
    status) emit_status;;
    set) set_auto "$2" "$3";;
    sync) sync_schedule && emit_status;;
    remove) remove_schedule && emit_status;;
    *) printf '%s\n' 'usage: geo-auto.sh {status|set <geoip|geosite> <0|1>|sync|remove}' >&2; exit 2;;
esac
