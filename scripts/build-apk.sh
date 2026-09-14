#!/usr/bin/env bash
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${OPENWRT_SDK:?OPENWRT_SDK is not set to an OpenWrt SDK directory}"
PACKAGE_NAME=luci-app-nftflow
SDK_PREP_REV="${SDK_PREP_REV:-1}"
SDK_PREPARED="$SDK/.nftflow-sdk-prepared-v$SDK_PREP_REV"
REQUIRED_EXECUTABLES=(
    root/etc/init.d/nftflow
    root/usr/libexec/nftflow/nftflowctl
)

package_version="$(sed -n 's/^PKG_VERSION[[:space:]]*:=[[:space:]]*//p' "$PROJECT/Makefile" | head -n1)"
package_release="$(sed -n 's/^PKG_RELEASE[[:space:]]*:=[[:space:]]*//p' "$PROJECT/Makefile" | head -n1)"
if [[ ! "$package_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$package_release" =~ ^[0-9]+$ ]]; then
    echo "Invalid PKG_VERSION or PKG_RELEASE in Makefile: ${package_version:-unset}-r${package_release:-unset}" >&2
    exit 1
fi
PACKAGE_VERSION="${package_version}-r${package_release}"

test -d "$SDK"
test -x "$SDK/staging_dir/host/bin/apk"
test -x "$SDK/staging_dir/host/bin/fakeroot"
command -v git >/dev/null

# LuCI preserves modes from root/ when packaging. Verify the Git index rather
# than the checkout filesystem so Windows cannot silently drop executable bits.
for relative in "${REQUIRED_EXECUTABLES[@]}"; do
    entry="$(git -C "$PROJECT" ls-files --stage -- "$relative")"
    mode="${entry%% *}"
    if [[ "$mode" != "100755" ]]; then
        echo "$relative must be tracked by Git with mode 100755 (found ${mode:-untracked})" >&2
        exit 1
    fi
done

# Official SDK archives do not always have the OpenWrt feeds materialized.
# Prepare the SDK once and retain the feed/build state in the cache. The
# sentinel is written only after every preparation step succeeds.
SECONDS=0
if [[ ! -f "$SDK_PREPARED" ]]; then
    test -x "$SDK/scripts/feeds"
    printf 'SDK preparation: updating feeds\n'
    "$SDK/scripts/feeds" update base packages luci
    printf 'SDK preparation: installing feeds\n'
    "$SDK/scripts/feeds" install -a >/dev/null
    test -f "$SDK/feeds/luci/luci.mk"
    if [[ ! -f "$SDK/.config" ]]; then
        printf 'SDK preparation: running defconfig\n'
        make -C "$SDK" defconfig
    fi
    touch "$SDK_PREPARED"
    printf 'SDK preparation: %ss\n' "$SECONDS"
else
    test -f "$SDK/feeds/luci/luci.mk"
    test -f "$SDK/.config"
    printf 'SDK preparation: cached (%ss)\n' "$SECONDS"
fi

PACKAGE_DIR="$SDK/package/$PACKAGE_NAME"
if [[ -e "$PACKAGE_DIR" ]]; then
    echo "Refusing to overwrite an existing SDK package directory: $PACKAGE_DIR" >&2
    exit 1
fi

OUT_DIR="$PROJECT/dist"
OUT="$OUT_DIR/$PACKAGE_NAME-$PACKAGE_VERSION.apk"
mkdir -p "$OUT_DIR"

# A prepared SDK cache can retain package artifacts from an earlier build.
# Remove only NftFlow APKs so a failed or partial rebuild cannot be mistaken for
# the current package. A clean SDK may not have created the output directory
# yet, so there is nothing to remove in that case.
apk_output_dir="$SDK/bin/packages"
if [[ -d "$apk_output_dir" ]]; then
    find "$apk_output_dir" -type f -name 'luci-app-nftflow*.apk' -delete
fi

EXTRACT_DIR=""
cleanup() {
    rm -rf "$PACKAGE_DIR"
    if [[ -n "$EXTRACT_DIR" ]]; then
        rm -rf "$EXTRACT_DIR"
    fi
}
trap cleanup EXIT

# Build the package from the normal OpenWrt package Makefile. This keeps
# dependency metadata, conffiles, maintainer scripts, and luci.mk behavior in
# the same path used by an image build and by the release workflow.
mkdir -p "$PACKAGE_DIR"
cp "$PROJECT/Makefile" "$PACKAGE_DIR/"
cp -a "$PROJECT/root" "$PROJECT/htdocs" "$PACKAGE_DIR/"
for relative in "${REQUIRED_EXECUTABLES[@]}"; do
    if [[ ! -x "$PACKAGE_DIR/$relative" ]]; then
        echo "Executable mode was not preserved for $relative" >&2
        exit 1
    fi
done

SECONDS=0
make -C "$SDK" package/$PACKAGE_NAME/clean package/$PACKAGE_NAME/compile V=s
printf 'Package compilation: %ss\n' "$SECONDS"

mapfile -t packages < <(find "$SDK/bin/packages" -type f -name "$PACKAGE_NAME-*.apk" -print | sort)
if (( ${#packages[@]} == 0 )); then
    echo "OpenWrt SDK did not produce $PACKAGE_NAME-$PACKAGE_VERSION.apk" >&2
    exit 1
fi

package=""
for candidate in "${packages[@]}"; do
    if [[ "$(basename "$candidate")" == "$PACKAGE_NAME-$PACKAGE_VERSION.apk" ]]; then
        package="$candidate"
        break
    fi
done
if [[ -z "$package" ]]; then
    echo "OpenWrt SDK did not produce $PACKAGE_NAME-$PACKAGE_VERSION.apk" >&2
    exit 1
fi

cp -f "$package" "$OUT"

APK_TOOL="$SDK/staging_dir/host/bin/apk"
EXTRACT_DIR="$(mktemp -d)"
(
    cd "$EXTRACT_DIR"
    "$APK_TOOL" --allow-untrusted extract "$OUT" >/dev/null
)
for relative in "${REQUIRED_EXECUTABLES[@]}"; do
    packaged="$EXTRACT_DIR/${relative#root/}"
    actual_mode="$(stat -c '%a' "$packaged" 2>/dev/null || true)"
    if [[ "$actual_mode" != "755" ]]; then
        echo "${relative#root/} mode is ${actual_mode:-missing}, expected 755" >&2
        exit 1
    fi
done

printf 'APK: %s\n' "$OUT"
