#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
case "$CONFIG" in debug|release) ;; *) echo "usage: $0 [debug|release]" >&2; exit 2;; esac
cd "$ROOT_DIR"
swift build --configuration "$CONFIG"
BIN_DIR="$(swift build --configuration "$CONFIG" --show-bin-path)"
FINAL_APP="$ROOT_DIR/build/$CONFIG/Dayreed.app"
APP_PATH="$FINAL_APP"
# Rebuild only this script's generated bundle. Runtime data never lives here.
if [[ -L "$ROOT_DIR/build" || -L "$ROOT_DIR/build/$CONFIG" || -L "$APP_PATH" ]]; then
    echo "Refusing a symlinked build destination." >&2
    exit 1
fi
mkdir -p "$ROOT_DIR/build/$CONFIG"
STAGING="$(mktemp -d "$ROOT_DIR/build/$CONFIG/.bundle.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP_PATH="$STAGING/Dayreed.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Helpers" "$APP_PATH/Contents/Resources"
ICON_PLIST="$STAGING/Icon-Info.plist"
xcrun actool "$ROOT_DIR/Resources/Branding/Dayreed.icon" \
    --compile "$APP_PATH/Contents/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon Dayreed \
    --output-partial-info-plist "$ICON_PLIST"
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
with Path(sys.argv[2]).open("rb") as f: p.update(plistlib.load(f))
with Path(sys.argv[3]).open("rb") as f: p.update(plistlib.load(f))
with (Path(sys.argv[1])/"Contents/Info.plist").open("wb") as f: plistlib.dump(p,f)
' "$APP_PATH" "$ICON_PLIST" "$ROOT_DIR/Resources/Updates/UpdateConfig.plist"
cp LICENSE "$APP_PATH/Contents/Resources/LICENSE"
mkdir -p "$APP_PATH/Contents/Frameworks"
# ditto preserves versioned framework symlinks and executable permissions.
ditto "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
cp "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP_PATH/Contents/Resources/Sparkle-LICENSE"
cp "$ROOT_DIR/script/install_cli.sh" "$APP_PATH/Contents/Resources/install_cli.sh"
# Local development signature; release preparation re-signs with Developer ID.
"$ROOT_DIR/script/sign_app.sh" "$APP_PATH" -
python3 "$ROOT_DIR/script/release_support.py" validate "$APP_PATH"
# Keep a previous successful bundle intact until this entire build has succeeded.
python3 "$ROOT_DIR/script/release_support.py" replace "$APP_PATH" "$FINAL_APP"
echo "$FINAL_APP"
