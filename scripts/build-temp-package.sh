#!/usr/bin/env bash
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${OPENWRT_SDK:?OPENWRT_SDK is not set to an OpenWrt SDK directory}"
UPSTREAM="${UPSTREAM_PACKAGES:?UPSTREAM_PACKAGES is not set}"
BASE_VERSION="${BASE_PACKAGE_VERSION:?BASE_PACKAGE_VERSION is not set}"
TARGET_VERSION="${TARGET_PACKAGE_VERSION:?TARGET_PACKAGE_VERSION is not set}"
ASSET_ARCH="${ASSET_ARCH:?ASSET_ARCH is not set}"

test -d "$SDK/feeds/packages"
test -d "$UPSTREAM"

mapfile -t base_makefiles < <(
    grep -rl --include=Makefile         "^PKG_VERSION:=$BASE_VERSION$"         "$SDK/feeds/packages" |
        sort
)

if (( ${#base_makefiles[@]} != 1 )); then
    echo "Expected exactly one package recipe at version $BASE_VERSION, found ${#base_makefiles[@]}" >&2
    exit 1
fi

base_makefile="${base_makefiles[0]}"
relative="${base_makefile#"$SDK/feeds/packages/"}"
upstream_makefile="$UPSTREAM/$relative"

test -f "$upstream_makefile"
grep -qx "PKG_VERSION:=$TARGET_VERSION" "$upstream_makefile"

base_name="$(sed -n 's/^PKG_NAME[[:space:]]*:=[[:space:]]*//p' "$base_makefile" | head -n1)"
upstream_name="$(sed -n 's/^PKG_NAME[[:space:]]*:=[[:space:]]*//p' "$upstream_makefile" | head -n1)"
[[ -n "$base_name" && "$base_name" == "$upstream_name" ]] || {
    echo "Package identity mismatch between stable and upstream recipes" >&2
    exit 1
}

base_source="$(sed -n 's/^PKG_SOURCE_URL[[:space:]]*:=[[:space:]]*//p' "$base_makefile" | head -n1)"
upstream_source="$(sed -n 's/^PKG_SOURCE_URL[[:space:]]*:=[[:space:]]*//p' "$upstream_makefile" | head -n1)"
[[ -n "$base_source" && "$base_source" == "$upstream_source" ]] || {
    echo "Package source changed upstream; refusing the temporary version-only update" >&2
    exit 1
}

target_release="$(sed -n 's/^PKG_RELEASE[[:space:]]*:=[[:space:]]*//p' "$upstream_makefile" | head -n1)"
target_hash="$(sed -n 's/^PKG_HASH[[:space:]]*:=[[:space:]]*//p' "$upstream_makefile" | head -n1)"

[[ "$target_release" =~ ^[0-9]+$ ]] || {
    echo "Invalid upstream package release" >&2
    exit 1
}
[[ "$target_hash" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Invalid upstream package hash" >&2
    exit 1
}

backup="$(mktemp)"
rendered="$(mktemp)"
cp "$base_makefile" "$backup"

cleanup() {
    cp "$backup" "$base_makefile"
    rm -f "$backup" "$rendered"
}
trap cleanup EXIT

awk     -v version="$TARGET_VERSION"     -v release="$target_release"     -v hash="$target_hash" '
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
        { print }
    ' "$base_makefile" > "$rendered"

mv "$rendered" "$base_makefile"

grep -qx "PKG_VERSION:=$TARGET_VERSION" "$base_makefile"
grep -qx "PKG_RELEASE:=$target_release" "$base_makefile"
grep -qx "PKG_HASH:=$target_hash" "$base_makefile"

package_dir="$(dirname "$base_makefile")"
package_key="$(basename "$package_dir")"
package_link="$SDK/package/feeds/packages/$package_key"
test -e "$package_link"

apk_output_dir="$SDK/bin/packages"
if [[ -d "$apk_output_dir" ]]; then
    find "$apk_output_dir" -type f -name "$base_name-*.apk" -delete
fi

build_log="$(mktemp)"
if ! make -C "$SDK"     "package/feeds/packages/$package_key/clean"     "package/feeds/packages/$package_key/compile"     >"$build_log" 2>&1; then
    tail -n 200 "$build_log" >&2
    rm -f "$build_log"
    exit 1
fi
rm -f "$build_log"

expected="$base_name-$TARGET_VERSION-r$target_release.apk"
mapfile -t packages < <(
    find "$SDK/bin/packages" -type f -name "$expected" -print | sort
)

if (( ${#packages[@]} != 1 )); then
    echo "Expected exactly one built APK, found ${#packages[@]}" >&2
    exit 1
fi

out_dir="$PROJECT/dist"
out="$out_dir/temporary-package-$TARGET_VERSION-r$target_release-$ASSET_ARCH.apk"
mkdir -p "$out_dir"
cp -f "${packages[0]}" "$out"

printf 'APK: %s\n' "$out"
