#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
case "$CONFIG" in debug|release) ;; *) echo "usage: $0 [debug|release]" >&2; exit 2;; esac
cd "$ROOT_DIR"
swift build --configuration "$CONFIG"
BIN_DIR="$(swift build --configuration "$CONFIG" --show-bin-path)"
APP_PATH="$ROOT_DIR/build/$CONFIG/Dayreed.app"
# Rebuild only this script's generated bundle. Runtime data never lives here.
if [[ -L "$ROOT_DIR/build" || -L "$ROOT_DIR/build/$CONFIG" || -L "$APP_PATH" ]]; then
    echo "Refusing a symlinked build destination." >&2
    exit 1
fi
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Helpers"
cp "$BIN_DIR/DayreedApp" "$APP_PATH/Contents/MacOS/Dayreed"
cp "$BIN_DIR/dayreed" "$APP_PATH/Contents/Helpers/dayreed"
"$BIN_DIR/dayreed" version --json | python3 -c '
import json, plistlib, sys
from pathlib import Path
v=json.load(sys.stdin)
p={"CFBundleExecutable":"Dayreed", "CFBundleIdentifier":v["bundleIdentifier"],
   "CFBundleName":v["name"], "CFBundleDisplayName":v["name"],
   "CFBundlePackageType":"APPL", "CFBundleShortVersionString":v["version"],
   "CFBundleVersion":str(v["build"]), "LSMinimumSystemVersion":v["minimumSystemVersion"],
   "NSPrincipalClass":"NSApplication", "NSHighResolutionCapable":True}
with (Path(sys.argv[1])/"Contents/Info.plist").open("wb") as f: plistlib.dump(p,f)
' "$APP_PATH"
cp LICENSE "$APP_PATH/Contents/LICENSE"
echo "$APP_PATH"
