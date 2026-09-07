#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dayreed-ui-checks.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$ROOT_DIR"
swiftc -module-cache-path "$TEST_DIR/modules" -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx26.0" \
  Sources/DayreedApp/Models/ReviewModels.swift Sources/DayreedApp/Services/ReviewService.swift \
  Sources/DayreedApp/Stores/ReviewStore.swift Sources/DayreedApp/Stores/SettingsStore.swift \
  Tests/DayreedUITests/SyntheticReviewService.swift Tests/DayreedUITests/ReviewStoreChecks.swift -o "$TEST_DIR/checks"
"$TEST_DIR/checks"
