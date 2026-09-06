#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
swift build --product DayreedApp
BIN_DIR="$(swift build --show-bin-path)"
APP_DIR="$ROOT_DIR/build/ui-preview/DayreedReviewPreview.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
UI_SOURCES=()
while IFS= read -r file; do UI_SOURCES+=("$file"); done < <(rg --files Sources/DayreedApp | sort | sed '/\/App\/DayreedApp.swift$/d')
swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx26.0" \
  -I "$BIN_DIR" -L "$BIN_DIR" -lDayreedCore -lDayreedCapture "${UI_SOURCES[@]}" \
  Tests/DayreedUITests/SyntheticReviewService.swift Tests/DayreedUITests/ReviewPreviewApp.swift \
  -o "$APP_DIR/Contents/MacOS/DayreedReviewPreview"
python3 - "$APP_DIR" <<'PY'
import plistlib,sys
from pathlib import Path
p={'CFBundleExecutable':'DayreedReviewPreview','CFBundleIdentifier':'YunaBuild.Dayreed.UIReview','CFBundleName':'Dayreed Review Preview','CFBundleShortVersionString':'1.0.0','CFBundleVersion':'1','CFBundlePackageType':'APPL','NSPrincipalClass':'NSApplication','LSMinimumSystemVersion':'26.0','NSHighResolutionCapable':True}
plistlib.dump(p,open(Path(sys.argv[1])/'Contents/Info.plist','wb'))
PY
printf '%s\n' "$APP_DIR"
