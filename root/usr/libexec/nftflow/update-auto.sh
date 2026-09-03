#!/bin/sh

. /usr/share/libubox/jshn.sh

CRONTAB=/etc/crontabs/root
TAG=nftflow-update-weekly
OLD_TAG=nftflow-geodata-weekly
SOFTWARE=/usr/libexec/nftflow/update.lua
GEODATA=/usr/libexec/nftflow/geo-update.lua
SCHEDULE='17 4 * * 0'
SCHEDULE_MINUTE=17
SCHEDULE_HOUR=4
SCHEDULE_DOW=0

flag() {
    local value
    value="$(uci -q get "nftflow.main.$1" 2>/dev/null || true)"
    [ "$value" = 1 ] && printf '1' || printf '0'
}

decimal() {
    local value="$1"
    case "$value" in 0*) value="${value#0}";; esac
    [ -n "$value" ] || value=0
    printf '%s' "$value"
}

days_in_month() {
    local year="$1" month="$2"
    case "$month" in
        1|3|5|7|8|10|12) printf '31';;
        4|6|9|11) printf '30';;
        2)
            if [ $((year % 400)) -eq 0 ] || { [ $((year % 4)) -eq 0 ] && [ $((year % 100)) -ne 0 ]; }; then
                printf '29'
            else
                printf '28'
            fi
            ;;
        *) return 1;;
    esac
}

next_check_local() {
    local fields year month day dow hour minute days dim
    fields="$(date '+%Y %m %d %w %H %M' 2>/dev/null)" || return 1
    set -- $fields
    [ "$#" -eq 6 ] || return 1

    year="$(decimal "$1")"
    month="$(decimal "$2")"
    day="$(decimal "$3")"
    dow="$(decimal "$4")"
    hour="$(decimal "$5")"
    minute="$(decimal "$6")"

    days=$(((SCHEDULE_DOW - dow + 7) % 7))
    if [ "$days" -eq 0 ] && { [ "$hour" -gt "$SCHEDULE_HOUR" ] || { [ "$hour" -eq "$SCHEDULE_HOUR" ] && [ "$minute" -ge "$SCHEDULE_MINUTE" ]; }; }; then
        days=7
    fi

    while [ "$days" -gt 0 ]; do
        dim="$(days_in_month "$year" "$month")" || return 1
        day=$((day + 1))
        if [ "$day" -gt "$dim" ]; then
            day=1
            month=$((month + 1))
            if [ "$month" -gt 12 ]; then
                month=1
                year=$((year + 1))
            fi
        fi
        days=$((days - 1))
    done

    printf '%04d-%02d-%02d %02d:%02d' "$year" "$month" "$day" "$SCHEDULE_HOUR" "$SCHEDULE_MINUTE"
}

reload_cron() {
    pidof crond >/dev/null 2>&1 || return 0
    /etc/init.d/cron reload >/dev/null 2>&1 || /etc/init.d/cron restart >/dev/null 2>&1 || true
}

clear_schedule_lines() {
    [ -f "$CRONTAB" ] || return 0
    sed -i "/$TAG/d;/$OLD_TAG/d" "$CRONTAB"
}

remove_schedule() {
    clear_schedule_lines || return 1
    reload_cron
}

sync_schedule() {
    mkdir -p /etc/crontabs || return 1
    touch "$CRONTAB" || return 1
    clear_schedule_lines || return 1
    if [ "$(flag update_check_enabled)" = 1 ]; then
        printf '%s\n' "$SCHEDULE $0 run >/dev/null 2>&1 # $TAG" >>"$CRONTAB" || return 1
    fi
    reload_cron
}

emit_status() {
    local scheduled=0 next_check='' timezone=''
    [ -f "$CRONTAB" ] && grep -Fq "# $TAG" "$CRONTAB" && scheduled=1
    if [ "$scheduled" = 1 ]; then
        next_check="$(next_check_local 2>/dev/null || true)"
        timezone="$(date +%Z 2>/dev/null || true)"
    fi
    json_init
    json_add_boolean ok 1
    json_add_boolean check_enabled "$(flag update_check_enabled)"
    json_add_boolean nftflow "$(flag nftflow_auto_update)"
    json_add_boolean xray "$(flag xray_auto_update)"
    json_add_boolean geoip "$(flag geoip_auto_update)"
    json_add_boolean geosite "$(flag geosite_auto_update)"
    json_add_boolean scheduled "$scheduled"
    json_add_string schedule "$SCHEDULE"
    json_add_string next_check "$next_check"
    json_add_string timezone "$timezone"
    json_dump
}

set_flag() {
    local option="$1" enabled="$2"
    case "$enabled" in 1|true|yes|on) enabled=1;; 0|false|no|off|'') enabled=0;; *) return 2;; esac
    uci -q set "nftflow.main.$option=$enabled" || return 1
    uci -q commit nftflow || return 1
}

check_one() {
    case "$1" in
        nftflow|xray) /usr/bin/lua "$SOFTWARE" check "$1";;
        geoip|geosite) /usr/bin/lua "$GEODATA" check "$1";;
        *) return 2;;
    esac
}

state_path() {
    case "$1" in
        nftflow|xray) printf '/tmp/nftflow-update/%s.json\n' "$1";;
        geoip|geosite) printf '/var/run/nftflow/geo-update-%s.json\n' "$1";;
    esac
}

checked_update_available() {
    local path raw available check_ok
    path="$(state_path "$1")"
    [ -s "$path" ] || return 1
    raw="$(cat "$path" 2>/dev/null)" || return 1
    json_load "$raw" 2>/dev/null || return 1
    json_get_var check_ok check_ok
    json_get_var available update_available
    [ "$check_ok" = 1 ] && [ "$available" = 1 ]
}

start_one() {
    case "$1" in
        nftflow|xray) /usr/bin/lua "$SOFTWARE" start "$1";;
        geoip|geosite) /usr/bin/lua "$GEODATA" start "$1";;
        *) return 2;;
    esac
}

wait_one() {
    local kind="$1" path raw status count=0
    path="$(state_path "$kind")"
    while [ "$count" -lt 600 ]; do
        [ -s "$path" ] || return 1
        raw="$(cat "$path" 2>/dev/null)" || return 1
        json_load "$raw" 2>/dev/null || return 1
        json_get_var status status
        case "$status" in done) return 0;; failed|stopped) return 1;; esac
        sleep 1
        count=$((count + 1))
    done
    logger -t nftflow-update "$kind automatic update timed out"
    return 1
}

auto_option() { printf '%s_auto_update\n' "$1"; }

run_checks() {
    local kind option result failed=0
    for kind in nftflow xray geoip geosite; do
        result="$(check_one "$kind" 2>&1)" || {
            logger -t nftflow-update "$kind scheduled check failed: $result"
            failed=1
        }
    done

    # Update data first, then Xray, and NftFlow itself last so package replacement
    # cannot interrupt the rest of this controller.
    for kind in geoip geosite xray nftflow; do
        option="$(auto_option "$kind")"
        [ "$(flag "$option")" = 1 ] || continue
        checked_update_available "$kind" || continue
        result="$(start_one "$kind" 2>&1)" || {
            logger -t nftflow-update "$kind automatic update could not start: $result"
            failed=1
            continue
        }
        wait_one "$kind" || {
            logger -t nftflow-update "$kind automatic update failed"
            failed=1
        }
    done
    return "$failed"
}

case "${1:-}" in
    status) emit_status;;
    set-check) set_flag update_check_enabled "$2" && sync_schedule && emit_status;;
    set-auto)
        case "$2" in nftflow|xray|geoip|geosite) ;; *) exit 2;; esac
        set_flag "$(auto_option "$2")" "$3" && emit_status
        ;;
    sync) sync_schedule && emit_status;;
    remove) remove_schedule && emit_status;;
    run) run_checks;;
    *) printf '%s\n' 'usage: update-auto.sh {status|set-check <0|1>|set-auto <kind> <0|1>|sync|remove|run}' >&2; exit 2;;
esac
