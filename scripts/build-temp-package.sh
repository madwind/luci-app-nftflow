#!/usr/bin/env bash
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${OPENWRT_SDK:?OPENWRT_SDK is not set to an OpenWrt SDK directory}"

required=(
    TEMP_PACKAGE_NAME
    TEMP_PACKAGE_VERSION
    TEMP_PACKAGE_RELEASE
    TEMP_PACKAGE_HASH
    TEMP_SOURCE_URL
    ASSET_ARCH
)
for name in "${required[@]}"; do
    [[ -n "${!name:-}" ]] || {
        echo "Missing required environment variable: $name" >&2
        exit 1
    }
done

test -d "$SDK"
test -d "$SDK/feeds/packages"

mapfile -t makefiles < <(
    grep -rl --include=Makefile         "^PKG_NAME:=${TEMP_PACKAGE_NAME}$"         "$SDK/feeds/packages" |
        sort
)

if (( ${#makefiles[@]} != 1 )); then
    echo "Expected exactly one matching package recipe, found ${#makefiles[@]}" >&2
    exit 1
fi

package_makefile="${makefiles[0]}"
package_dir="$(dirname "$package_makefile")"
package_key="$(basename "$package_dir")"
package_link="$SDK/package/feeds/packages/$package_key"

test -e "$package_link"

backup="$(mktemp)"
rendered="$(mktemp)"
cp "$package_makefile" "$backup"

cleanup() {
    cp "$backup" "$package_makefile"
    rm -f "$backup" "$rendered"
}
trap cleanup EXIT

awk     -v version="$TEMP_PACKAGE_VERSION"     -v release="$TEMP_PACKAGE_RELEASE"     -v hash="$TEMP_PACKAGE_HASH"     -v source="$TEMP_SOURCE_URL" '
        /^PKG_VERSION:=/ {
            print "PKG_VERSION:=" version
            next
        }
        /^PKG_RELEASE:=/ {
            print "PKG_RELEASE:=" release
            next
        }
        /^PKG_HASH:=/ {
            print "PKG_HASH:=" hash
            next
        }
        /^PKG_SOURCE_URL:=/ {
            print "PKG_SOURCE_URL:=" source
            next
        }
        { print }
    ' "$package_makefile" > "$rendered"

mv "$rendered" "$package_makefile"

grep -qx "PKG_VERSION:=$TEMP_PACKAGE_VERSION" "$package_makefile"
grep -qx "PKG_RELEASE:=$TEMP_PACKAGE_RELEASE" "$package_makefile"
grep -qx "PKG_HASH:=$TEMP_PACKAGE_HASH" "$package_makefile"
grep -Fqx "PKG_SOURCE_URL:=$TEMP_SOURCE_URL" "$package_makefile"

apk_output_dir="$SDK/bin/packages"
if [[ -d "$apk_output_dir" ]]; then
    find "$apk_output_dir" -type f         -name "${TEMP_PACKAGE_NAME}-*.apk"         -delete
fi

make -C "$SDK"     "package/feeds/packages/$package_key/clean"     "package/feeds/packages/$package_key/compile"     V=s

expected="${TEMP_PACKAGE_NAME}-${TEMP_PACKAGE_VERSION}-r${TEMP_PACKAGE_RELEASE}.apk"
mapfile -t packages < <(
    find "$SDK/bin/packages" -type f -name "$expected" -print | sort
)

if (( ${#packages[@]} != 1 )); then
    echo "Expected exactly one built APK, found ${#packages[@]}" >&2
    exit 1
fi

out_dir="$PROJECT/dist"
out="$out_dir/temporary-package-${TEMP_PACKAGE_VERSION}-r${TEMP_PACKAGE_RELEASE}-${ASSET_ARCH}.apk"
mkdir -p "$out_dir"
cp -f "${packages[0]}" "$out"

printf 'APK: %s\n' "$out"
