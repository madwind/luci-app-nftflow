#!/bin/sh

UPDATE=/usr/libexec/nftflow/update.uc

case "${1:-status}" in
    status) exec /usr/bin/ucode "$UPDATE" auto-status ;;
    set-check) exec /usr/bin/ucode "$UPDATE" auto-set-check "${2:-0}" ;;
    set-auto) exec /usr/bin/ucode "$UPDATE" auto-set "${2:-}" "${3:-0}" ;;
    sync) exec /usr/bin/ucode "$UPDATE" auto-sync ;;
    remove) exec /usr/bin/ucode "$UPDATE" auto-remove ;;
    run) exec /usr/bin/ucode "$UPDATE" auto-run ;;
    *) printf '%s\n' '{"ok":false,"error":"unknown automatic update command"}'; exit 1 ;;
esac
