#!/bin/sh

. /usr/share/libubox/jshn.sh

CRONTAB=/etc/crontabs/root
TAG=nftflow-update-weekly
OLD_TAG=nftflow-geodata-weekly
SOFTWARE=/usr/libexec/nftflow/update.lua
GEODATA=/usr/libexec/nftflow/geo-update.lua
CTL=/usr/libexec/nftflow/nftflowctl
BATCH_BACKUP=/tmp/nftflow-update/batch-backup
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
        if [ -n "$next_check" ]; then
            timezone="$(date -d "$next_check:00" +%Z 2>/dev/null || date +%Z 2>/dev/null || true)"
        fi
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
        nftflow|xray) NFTFLOW_DEFER_RESTART=1 /usr/bin/lua "$SOFTWARE" start "$1";;
        geoip|geosite) NFTFLOW_DEFER_RESTART=1 /usr/bin/lua "$GEODATA" start "$1";;
        *) return 2;;
    esac
}

wait_one() {
    local kind="$1" path raw status updated count=0
    path="$(state_path "$kind")"
    while [ "$count" -lt 600 ]; do
        [ -s "$path" ] || return 1
        raw="$(cat "$path" 2>/dev/null)" || return 1
        json_load "$raw" 2>/dev/null || return 1
        json_get_var status status
        case "$status" in
            done)
                json_get_var updated updated
                [ "$updated" = 1 ]
                return
                ;;
            failed|stopped) return 1;;
        esac
        sleep 1
        count=$((count + 1))
    done
    logger -t nftflow-update "$kind automatic update timed out"
    return 1
}

runtime_running() {
    local raw running
    raw="$($CTL status 2>/dev/null)" || return 1
    json_load "$raw" 2>/dev/null || return 1
    json_get_var running running
    [ "$running" = 1 ]
}

wait_runtime_running() {
    local stable=0 count=0
    while [ "$count" -lt 6 ]; do
        if runtime_running; then
            stable=$((stable + 1))
            [ "$stable" -ge 3 ] && return 0
        else
            stable=0
        fi
        sleep 1
        count=$((count + 1))
    done
    return 1
}

geo_asset_path() {
    local kind="$1" asset_dir configured
    asset_dir="$(uci -q get nftflow.main.asset_dir 2>/dev/null || true)"
    [ -n "$asset_dir" ] || asset_dir=/usr/share/xray
    configured="$(uci -q get "nftflow.main.${kind}_file" 2>/dev/null || true)"
    [ -n "$configured" ] && printf '%s\n' "$configured" || printf '%s/%s.dat\n' "$asset_dir" "$kind"
}

snapshot_geo() {
    local kind="$1" asset version_path
    asset="$(geo_asset_path "$kind")" || return 1
    version_path="$asset.version"
    mkdir -p "$BATCH_BACKUP" || return 1
    rm -f "$BATCH_BACKUP/$kind.dat" "$BATCH_BACKUP/$kind.version" \
        "$BATCH_BACKUP/$kind.had-file" "$BATCH_BACKUP/$kind.had-version"
    if [ -f "$asset" ]; then
        cp -p "$asset" "$BATCH_BACKUP/$kind.dat" || return 1
        touch "$BATCH_BACKUP/$kind.had-file" || return 1
    fi
    if [ -f "$version_path" ]; then
        cp -p "$version_path" "$BATCH_BACKUP/$kind.version" || return 1
        touch "$BATCH_BACKUP/$kind.had-version" || return 1
    fi
    return 0
}

restore_geo() {
    local kind="$1" asset version_path
    asset="$(geo_asset_path "$kind")" || return 1
    version_path="$asset.version"
    mkdir -p "${asset%/*}" || return 1
    if [ -e "$BATCH_BACKUP/$kind.had-file" ]; then
        cp -p "$BATCH_BACKUP/$kind.dat" "$asset" || return 1
    else
        rm -f "$asset"
    fi
    if [ -e "$BATCH_BACKUP/$kind.had-version" ]; then
        cp -p "$BATCH_BACKUP/$kind.version" "$version_path" || return 1
    else
        rm -f "$version_path"
    fi
    return 0
}

restore_all_geo() {
    local kind
    for kind in geoip geosite; do
        [ -e "$BATCH_BACKUP/$kind.had-file" ] || [ -e "$BATCH_BACKUP/$kind.had-version" ] || continue
        restore_geo "$kind" || logger -t nftflow-update "$kind rollback after batch restart failure failed"
    done
}

clear_batch_backup() {
    rm -rf "$BATCH_BACKUP"
}

auto_option() { printf '%s_auto_update\n' "$1"; }

run_checks() {
    local kind option result failed=0 did_update=0 was_running=0
    runtime_running && was_running=1
    clear_batch_backup

    for kind in nftflow xray geoip geosite; do
        result="$(check_one "$kind" 2>&1)" || {
            logger -t nftflow-update "$kind scheduled check failed: $result"
            failed=1
        }
    done

    # Update data first, then Xray, and NftFlow itself last. Component workers
    # defer service restarts so the whole batch reloads Xray at most once.
    for kind in geoip geosite xray nftflow; do
        option="$(auto_option "$kind")"
        [ "$(flag "$option")" = 1 ] || continue
        checked_update_available "$kind" || continue

        case "$kind" in
            geoip|geosite)
                snapshot_geo "$kind" || {
                    logger -t nftflow-update "$kind automatic update backup failed"
                    failed=1
                    continue
                }
                ;;
        esac

        result="$(start_one "$kind" 2>&1)" || {
            logger -t nftflow-update "$kind automatic update could not start: $result"
            case "$kind" in geoip|geosite) restore_geo "$kind" || true;; esac
            failed=1
            continue
        }
        if wait_one "$kind"; then
            did_update=1
        else
            logger -t nftflow-update "$kind automatic update failed"
            case "$kind" in geoip|geosite) restore_geo "$kind" || true;; esac
            failed=1
        fi
    done

    if [ "$did_update" = 1 ] && [ "$was_running" = 1 ]; then
        /etc/init.d/nftflow restart >/dev/null 2>&1 || true
        if wait_runtime_running; then
            clear_batch_backup
            return "$failed"
        fi

        logger -t nftflow-update 'NftFlow did not remain running after the automatic update batch; stopping retries and restoring previous GeoData'
        /etc/init.d/nftflow stop >/dev/null 2>&1 || true
        restore_all_geo
        if /etc/init.d/nftflow start >/dev/null 2>&1 && wait_runtime_running; then
            logger -t nftflow-update 'NftFlow recovered after restoring previous GeoData'
        else
            /etc/init.d/nftflow stop >/dev/null 2>&1 || true
            logger -t nftflow-update 'NftFlow recovery failed; service was left stopped to prevent a respawn loop'
        fi
        failed=1
    elif [ "$did_update" = 0 ] && [ "$was_running" = 1 ] && ! runtime_running; then
        # A failed package replacement may have stopped the service. Try once,
        # then stop it explicitly if it cannot remain up.
        /etc/init.d/nftflow start >/dev/null 2>&1 || true
        if ! wait_runtime_running; then
            /etc/init.d/nftflow stop >/dev/null 2>&1 || true
            logger -t nftflow-update 'NftFlow recovery after a failed automatic update did not stabilize; service was left stopped'
            failed=1
        fi
    fi

    clear_batch_backup
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
