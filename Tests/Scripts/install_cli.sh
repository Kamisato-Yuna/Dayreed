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
        {"CFBundleIdentifier": "YunaBuild.Dayreed"},
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

"$installer" install --app "$app_path" --bin-dir "$bin_dir"
link_path="$bin_dir/dayreed"
[[ -L "$link_path" ]]
[[ "$(readlink "$link_path")" == "$helper_path" ]]
[[ "$("$link_path" version --json)" == *'"bundleIdentifier":"YunaBuild.Dayreed"'* ]]

"$installer" install --app "$app_path" --bin-dir "$bin_dir"
[[ -L "$link_path" ]]

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
