#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dayreed-branding.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
cd "$ROOT_DIR"
swiftc -module-cache-path "$TEMP_DIR/modules" -parse-as-library -swift-version 6 \
  Sources/DayreedApp/Support/ReedMark.swift script/export_branding.swift -o "$TEMP_DIR/export-branding"
"$TEMP_DIR/export-branding" "$ROOT_DIR/Resources/Branding/MenuBar"
# App icons are compiled from the real Icon Composer document, never flattened first.
OUTPUT_DIR="${1:-$ROOT_DIR/build/branding}"
mkdir -p "$OUTPUT_DIR"
xcrun actool Resources/Branding/Dayreed.icon --compile "$OUTPUT_DIR" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon Dayreed --output-partial-info-plist "$OUTPUT_DIR/Icon-Info.plist"
