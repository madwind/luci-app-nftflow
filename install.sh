#!/bin/sh
set -eu

BASE='https://github.com/madwind/luci-app-nftflow/releases'
TMP="/tmp/nftflow-install.$$"
MANIFEST="$TMP/nftflow-update.json"

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

command -v apk >/dev/null 2>&1 || die 'apk is required (OpenWrt 25.12+)'
command -v wget >/dev/null 2>&1 || die 'wget is required'
command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required'

mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

printf 'Downloading NftFlow release metadata...\n'
wget -q -O "$MANIFEST" "$BASE/latest/download/nftflow-update.json" || die 'failed to download release metadata'

json_get() {
    awk -F '"' -v key="$1" '$2 == key { print $4; exit }' "$MANIFEST"
}

VERSION="$(json_get version)"
TAG="$(json_get tag)"
ASSET="$(json_get asset)"
SHA256="$(json_get sha256)"

[ -n "$VERSION" ] || die 'missing version in release metadata'
[ -n "$TAG" ] || die 'missing tag in release metadata'
[ -n "$ASSET" ] || die 'missing asset in release metadata'
[ -n "$SHA256" ] || die 'missing sha256 in release metadata'

case "$TAG" in *[!A-Za-z0-9._+-]*) die 'invalid release tag' ;; esac
case "$ASSET" in luci-app-nftflow-*.apk) ;; *) die 'invalid package asset' ;; esac
case "$SHA256" in *[!0-9A-Fa-f]*) die 'invalid SHA256' ;; esac
[ "${#SHA256}" -eq 64 ] || die 'invalid SHA256 length'

PACKAGE="$TMP/$ASSET"
URL="$BASE/download/$TAG/$ASSET"

printf 'Downloading NftFlow %s...\n' "$VERSION"
wget -O "$PACKAGE" "$URL" || die 'package download failed'

ACTUAL="$(sha256sum "$PACKAGE" | awk '{ print $1 }')"
[ "$ACTUAL" = "$SHA256" ] || die 'SHA256 verification failed'

printf 'Updating package indexes...\n'
apk update || die 'apk update failed'

printf 'Installing %s...\n' "$ASSET"
apk add --allow-untrusted --upgrade "$PACKAGE" || die 'package installation failed'

printf '[OK] NftFlow %s installed successfully.\n' "$VERSION"
