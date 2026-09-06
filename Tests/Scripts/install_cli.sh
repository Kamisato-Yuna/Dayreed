#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
installer="${repo_root}/script/install_cli.sh"
test_root="$(mktemp -d /private/tmp/dayreed-cli-test.XXXXXX)"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

app_path="${test_root}/Synthetic Dayreed.app"
helper_path="${app_path}/Contents/Helpers/dayreed"
bin_dir="${test_root}/bin with spaces"
mkdir -p "$(dirname "$helper_path")" "$bin_dir"

python3 - "$app_path/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as plist_file:
    plistlib.dump(
        {
            "CFBundleIdentifier": "YunaBuild.Dayreed",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
        },
        plist_file,
        fmt=plistlib.FMT_XML,
    )
PY

cat > "$helper_path" <<'HELPER'
#!/usr/bin/env bash

if [[ "${1:-}" == "version" && "${2:-}" == "--json" ]]; then
  printf '%s\n' '{"name":"Dayreed","version":"1.0.0","build":1,"bundleIdentifier":"YunaBuild.Dayreed","minimumSystemVersion":"26.0"}'
  exit 0
fi

printf '%s\n' 'unexpected helper arguments' >&2
exit 1
HELPER
chmod +x "$helper_path"

help_output="$($installer --help)"
[[ "$help_output" == *"install_cli.sh install"* ]]
[[ "$help_output" == *"~/.local/bin"* ]]

missing_uninstall_dir="${test_root}/missing uninstall"
"$installer" uninstall --app "$app_path" --bin-dir "$missing_uninstall_dir"
[[ ! -e "$missing_uninstall_dir" ]]

invalid_app_path="${test_root}/Invalid Dayreed.app"
invalid_app_bin_dir="${test_root}/invalid app bin"
if "$installer" install --app "$invalid_app_path" --bin-dir "$invalid_app_bin_dir"; then
  printf '%s\n' 'invalid App was not rejected' >&2
  exit 1
fi
[[ ! -e "$invalid_app_bin_dir" ]]

"$installer" install --app "$app_path" --bin-dir "$bin_dir"
link_path="$bin_dir/dayreed"
[[ -L "$link_path" ]]
[[ "$(readlink "$link_path")" == "$helper_path" ]]
[[ "$("$link_path" version --json)" == *'"bundleIdentifier":"YunaBuild.Dayreed"'* ]]

"$installer" install --app "$app_path" --bin-dir "$bin_dir"
[[ -L "$link_path" ]]

version_mismatch_bin_dir="${test_root}/version mismatch"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 9.9.9' "$app_path/Contents/Info.plist"
if "$installer" install --app "$app_path" --bin-dir "$version_mismatch_bin_dir"; then
  printf '%s\n' 'version mismatch was not rejected' >&2
  exit 1
fi
[[ ! -e "$version_mismatch_bin_dir" ]]
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.0.0' "$app_path/Contents/Info.plist"

build_mismatch_bin_dir="${test_root}/build mismatch"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 2' "$app_path/Contents/Info.plist"
if "$installer" install --app "$app_path" --bin-dir "$build_mismatch_bin_dir"; then
  printf '%s\n' 'build mismatch was not rejected' >&2
  exit 1
fi
[[ ! -e "$build_mismatch_bin_dir" ]]
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 1' "$app_path/Contents/Info.plist"

regular_bin_dir="${test_root}/regular conflict"
mkdir -p "$regular_bin_dir"
printf '%s\n' 'keep me' > "$regular_bin_dir/dayreed"
if "$installer" install --app "$app_path" --bin-dir "$regular_bin_dir"; then
  printf '%s\n' 'regular-file conflict was not rejected' >&2
  exit 1
fi
[[ "$(cat "$regular_bin_dir/dayreed")" == "keep me" ]]

foreign_bin_dir="${test_root}/foreign conflict"
mkdir -p "$foreign_bin_dir"
ln -s /bin/sh "$foreign_bin_dir/dayreed"
if "$installer" install --app "$app_path" --bin-dir "$foreign_bin_dir"; then
  printf '%s\n' 'foreign-link conflict was not rejected' >&2
  exit 1
fi
[[ "$(readlink "$foreign_bin_dir/dayreed")" == "/bin/sh" ]]

if "$installer" install --app "$app_path" --bin-dir /usr/local; then
  printf '%s\n' '/usr/local was not rejected' >&2
  exit 1
fi

"$installer" uninstall --app "$app_path" --bin-dir "$bin_dir"
[[ ! -e "$link_path" && ! -L "$link_path" ]]
[[ -x "$helper_path" ]]
[[ -f "$app_path/Contents/Info.plist" ]]

if "$installer" uninstall --app "$app_path" --bin-dir "$foreign_bin_dir"; then
  printf '%s\n' 'foreign-link uninstall was not rejected' >&2
  exit 1
fi
[[ "$(readlink "$foreign_bin_dir/dayreed")" == "/bin/sh" ]]

printf '%s\n' 'PASS: install, repeat, spaces, conflicts, /usr/local guard, and uninstall'
