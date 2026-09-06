#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dayreed-live-checks.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
export CLANG_MODULE_CACHE_PATH="$TEST_DIR/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$TEST_DIR/swift"
if [[ -n "${DAYREED_TEST_BIN_DIR:-}" ]]; then
  BIN_DIR="$DAYREED_TEST_BIN_DIR"
else
  swift build --disable-sandbox --cache-path "$TEST_DIR/cache" --product DayreedApp
  BIN_DIR="$(swift build --disable-sandbox --show-bin-path)"
fi
swiftc -module-cache-path "$TEST_DIR/modules" -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx26.0" \
  -I "$BIN_DIR" -L "$BIN_DIR" -lDayreedCore -lDayreedCapture \
  Sources/DayreedApp/Models/ReviewModels.swift Sources/DayreedApp/Services/*.swift \
  Tests/DayreedUITests/AppSyntheticEnvironment.swift Tests/DayreedUITests/LiveServiceChecks.swift -o "$TEST_DIR/checks"
"$TEST_DIR/checks"
