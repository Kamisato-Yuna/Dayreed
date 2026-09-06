#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dayreed-review-preview.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
MODULE_DIR="$TEST_DIR/modules"
Tests/DayreedUITests/compile_test_modules.sh "$MODULE_DIR" --updates
SPARKLE_DIR="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
APP_DIR="$ROOT_DIR/build/ui-preview/DayreedReviewPreview.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
UI_SOURCES=()
while IFS= read -r file; do UI_SOURCES+=("$file"); done < <(rg --files Sources/DayreedApp -g '*.swift' | sort | sed '/\/App\/DayreedApp.swift$/d')
swiftc -module-cache-path "$MODULE_DIR/cache" -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx26.0" \
  -I "$MODULE_DIR" -L "$MODULE_DIR" -lDayreedCore -lDayreedCapture -lDayreedAnalysis -lDayreedUpdate \
  -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "${UI_SOURCES[@]}" Tests/DayreedUITests/SyntheticReviewService.swift Tests/DayreedUITests/ReviewPreviewApp.swift \
  -o "$APP_DIR/Contents/MacOS/DayreedReviewPreview"
cp "$MODULE_DIR"/*.dylib "$APP_DIR/Contents/Frameworks/"
ditto "$SPARKLE_DIR/Sparkle.framework" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
python3 - "$APP_DIR" <<'PY'
import plistlib,sys
from pathlib import Path
p={'CFBundleExecutable':'DayreedReviewPreview','CFBundleIdentifier':'YunaBuild.Dayreed.UIReview','CFBundleName':'Dayreed Review Preview','CFBundleShortVersionString':'1.0.0','CFBundleVersion':'1','CFBundlePackageType':'APPL','NSPrincipalClass':'NSApplication','LSMinimumSystemVersion':'26.0','NSHighResolutionCapable':True}
plistlib.dump(p,open(Path(sys.argv[1])/'Contents/Info.plist','wb'))
PY
printf '%s\n' "$APP_DIR"
