#!/usr/bin/env bash
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${OPENWRT_SDK:?OPENWRT_SDK is not set to an OpenWrt SDK directory}"
STABLE="${STABLE_PACKAGES:?STABLE_PACKAGES is not set}"
UPSTREAM="${UPSTREAM_PACKAGES:?UPSTREAM_PACKAGES is not set}"
BASE_VERSION="${BASE_PACKAGE_VERSION:?BASE_PACKAGE_VERSION is not set}"
TARGET_VERSION="${TARGET_PACKAGE_VERSION:?TARGET_PACKAGE_VERSION is not set}"
TEMP_RELEASE="${TEMP_PACKAGE_RELEASE:?TEMP_PACKAGE_RELEASE is not set}"
ASSET_ARCH="${ASSET_ARCH:?ASSET_ARCH is not set}"
ASSET_SUFFIX="${ASSET_SUFFIX:?ASSET_SUFFIX is not set}"

APK_TOOL="$SDK/staging_dir/host/bin/apk"
FAKEROOT="$SDK/staging_dir/host/bin/fakeroot"

test -x "$APK_TOOL"
test -x "$FAKEROOT"
test -d "$STABLE"
test -d "$UPSTREAM"

mapfile -t base_makefiles < <(
    grep -rl --include=Makefile         "^PKG_VERSION:=$BASE_VERSION$"         "$STABLE" |
        sort
)

if (( ${#base_makefiles[@]} != 1 )); then
    echo "Expected exactly one stable package recipe at version $BASE_VERSION, found ${#base_makefiles[@]}" >&2
    exit 1
fi

base_makefile="${base_makefiles[0]}"
relative="${base_makefile#"$STABLE/"}"
upstream_makefile="$UPSTREAM/$relative"

test -f "$upstream_makefile"
grep -qx "PKG_VERSION:=$TARGET_VERSION" "$upstream_makefile"

package_name="$(sed -n 's/^PKG_NAME[[:space:]]*:=[[:space:]]*//p' "$base_makefile" | head -n1)"
upstream_name="$(sed -n 's/^PKG_NAME[[:space:]]*:=[[:space:]]*//p' "$upstream_makefile" | head -n1)"
[[ -n "$package_name" && "$package_name" == "$upstream_name" ]] || {
    echo "Package identity mismatch between stable and upstream recipes" >&2
    exit 1
}

source_url="$(sed -n 's/^PKG_SOURCE_URL[[:space:]]*:=[[:space:]]*//p' "$upstream_makefile" | head -n1)"
repo_path="$(printf '%s\n' "$source_url" | sed -n 's#^https://codeload.github.com/\([^/]*/[^/]*\)/tar.gz/.*#\1#p')"
[[ -n "$repo_path" ]] || {
    echo "Unable to derive the upstream repository from the package recipe" >&2
    exit 1
}

binary_name="$(
    sed -n         's#.*$(INSTALL_BIN)[[:space:]]*$(PKG_INSTALL_DIR)/usr/bin/main[[:space:]]*$(1)/usr/bin/\([^[:space:]]*\).*#\1#p'         "$base_makefile" |
        head -n1
)"
[[ -n "$binary_name" ]] || {
    echo "Unable to derive the installed binary name from the stable package recipe" >&2
    exit 1
}

license="$(sed -n 's/^PKG_LICENSE[[:space:]]*:=[[:space:]]*//p' "$base_makefile" | head -n1)"
[[ -n "$license" ]] || license="unknown"

release_json="$(mktemp)"
archive="$(mktemp)"
extract_dir="$(mktemp -d)"
package_root="$(mktemp -d)"

cleanup() {
    rm -f "$release_json" "$archive"
    rm -rf "$extract_dir" "$package_root"
}
trap cleanup EXIT

curl \
    --fail \
    --location \
    --retry 5 \
    --retry-all-errors \
    --show-error \
    --output "$release_json" \
    "https://api.github.com/repos/$repo_path/releases/tags/v$TARGET_VERSION"

asset_url="$(
    python3 - "$release_json" "$ASSET_SUFFIX" <<'PY'
import json
import sys

path, suffix = sys.argv[1:]
with open(path, "r", encoding="utf-8") as f:
    release = json.load(f)

matches = [
    asset.get("browser_download_url", "")
    for asset in release.get("assets", [])
    if asset.get("name", "").endswith(suffix)
]

if len(matches) != 1 or not matches[0]:
    raise SystemExit(f"expected exactly one release asset ending with {suffix}, found {len(matches)}")

print(matches[0])
PY
)"

curl \
    --fail \
    --location \
    --retry 5 \
    --retry-all-errors \
    --show-error \
    --output "$archive" \
    "$asset_url"

python3 -m zipfile -e "$archive" "$extract_dir"

mapfile -t binaries < <(find "$extract_dir" -type f -name "$binary_name" -print)
if (( ${#binaries[@]} != 1 )); then
    echo "Expected exactly one release binary named $binary_name, found ${#binaries[@]}" >&2
    exit 1
fi

install -D -m 0755 "${binaries[0]}" "$package_root/usr/bin/$binary_name"

package_dir="$(dirname "$base_makefile")"
while IFS= read -r line; do
    case "$line" in
        *'$(CURDIR)/files/'*'$(1)'*) ;;
        *) continue ;;
    esac

    kind="$(printf '%s\n' "$line" | sed -n 's/.*$(INSTALL_\([A-Z]*\)).*/\1/p')"
    source_rel="$(printf '%s\n' "$line" | sed -n 's#.*$(CURDIR)/files/\([^[:space:]]*\).*#\1#p')"
    destination="$(printf '%s\n' "$line" | sed -n 's#.*$(1)\([^[:space:]]*\).*#\1#p')"

    [[ -n "$kind" && -n "$source_rel" && -n "$destination" ]] || continue
    source_file="$package_dir/files/$source_rel"
    test -f "$source_file"

    if [[ "$destination" == */ ]]; then
        destination="$destination$(basename "$source_rel")"
    fi

    mode=0644
    [[ "$kind" == "BIN" ]] && mode=0755
    install -D -m "$mode" "$source_file" "$package_root$destination"
done < "$base_makefile"

out_dir="$PROJECT/dist"
out="$out_dir/temporary-package-$TARGET_VERSION-r$TEMP_RELEASE-$ASSET_ARCH.apk"
mkdir -p "$out_dir"

"$FAKEROOT" "$APK_TOOL" mkpkg \
    --info "name:$package_name" \
    --info "version:$TARGET_VERSION-r$TEMP_RELEASE" \
    --info "description:Temporary upstream package" \
    --info "arch:$ASSET_ARCH" \
    --info "license:$license" \
    --info "origin:feeds/packages/$relative" \
    --info "provides:" \
    --info "depends:ca-bundle" \
    --files "$package_root" \
    --output "$out"

test -s "$out"
printf 'APK: %s\n' "$out"
