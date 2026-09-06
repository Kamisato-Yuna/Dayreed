#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dayreed-live-preview.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
MODULE_DIR="$TEST_DIR/modules"
Tests/DayreedUITests/compile_test_modules.sh "$MODULE_DIR" --updates
SPARKLE_DIR="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
APP_DIR="$PWD/build/live-preview/DayreedLivePreview.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Frameworks"
UI_SOURCES=()
while IFS= read -r file; do UI_SOURCES+=("$file"); done < <(/usr/bin/find Sources/DayreedApp -type f -name '*.swift' -print | LC_ALL=C sort | sed '/\/App\/DayreedApp.swift$/d')
swiftc -module-cache-path "$MODULE_DIR/cache" -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx26.0" \
  -I "$MODULE_DIR" -L "$MODULE_DIR" -lDayreedCore -lDayreedCapture -lDayreedAnalysis -lDayreedUpdate \
  -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "${UI_SOURCES[@]}" Tests/DayreedUITests/AppSyntheticEnvironment.swift Tests/DayreedUITests/AppSyntheticAnalysis.swift \
  Tests/DayreedUITests/LivePreviewApp.swift -o "$APP_DIR/Contents/MacOS/DayreedLivePreview"
cp "$MODULE_DIR"/*.dylib "$APP_DIR/Contents/Frameworks/"
ditto "$SPARKLE_DIR/Sparkle.framework" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
python3 - "$APP_DIR" <<'PY'
import plistlib,sys
from pathlib import Path
p={'CFBundleExecutable':'DayreedLivePreview','CFBundleIdentifier':'YunaBuild.Dayreed.LivePreview','CFBundleName':'Dayreed Live Preview','CFBundleShortVersionString':'0.1.0','CFBundleVersion':'1','CFBundlePackageType':'APPL','NSPrincipalClass':'NSApplication','LSMinimumSystemVersion':'26.0','NSHighResolutionCapable':True}
plistlib.dump(p,open(Path(sys.argv[1])/'Contents/Info.plist','wb'))
PY
printf '%s\n' "$APP_DIR"
