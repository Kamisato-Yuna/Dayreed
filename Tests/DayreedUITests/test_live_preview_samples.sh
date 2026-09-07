#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dayreed-live-checks.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
MODULE_DIR="$TEST_DIR/modules"
Tests/DayreedUITests/compile_test_modules.sh "$MODULE_DIR"
swiftc -module-cache-path "$MODULE_DIR/cache" -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx26.0" \
  -I "$MODULE_DIR" -L "$MODULE_DIR" -lDayreedCore -lDayreedCapture -lDayreedAnalysis \
  -Xlinker -rpath -Xlinker @executable_path/modules \
  Sources/DayreedApp/Models/ReviewModels.swift Sources/DayreedApp/Models/ProviderDraft.swift Sources/DayreedApp/Services/*.swift \
  Tests/DayreedUITests/AppSyntheticEnvironment.swift Tests/DayreedUITests/AppSyntheticAnalysis.swift \
  Tests/DayreedUITests/LivePreviewSampleChecks.swift Tests/DayreedUITests/LivePreviewSamples.swift \
  -o "$TEST_DIR/checks"
"$TEST_DIR/checks"
