#!/usr/bin/env bash
# Compile the real modules explicitly: SwiftPM automatic libraries have different artifact
# layouts across Xcode 26 and 27. No generated manifest or alternative implementation is used.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE_DIR="$1"
mkdir -p "$MODULE_DIR"
cd "$ROOT_DIR"
COMMON=(-parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx26.0" -module-cache-path "$MODULE_DIR/cache")
compile_module() {
  local name="$1"
  shift
  local sources=()
  while IFS= read -r file; do sources+=("$file"); done < <(rg --files "Sources/$name" -g '*.swift' | sort)
  swiftc "${COMMON[@]}" -emit-module -emit-library -module-name "$name" \
    -emit-module-path "$MODULE_DIR/$name.swiftmodule" -I "$MODULE_DIR" -L "$MODULE_DIR" \
    -Xlinker -install_name -Xlinker "@rpath/lib$name.dylib" -Xlinker -rpath -Xlinker @loader_path \
    "${sources[@]}" "$@" -o "$MODULE_DIR/lib$name.dylib"
}
compile_module DayreedCore -lsqlite3
compile_module DayreedCapture -lDayreedCore
compile_module DayreedAnalysis -lDayreedCore
if [[ "${2:-}" == "--updates" ]]; then
  SPARKLE_DIR="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
  if [[ ! -d "$SPARKLE_DIR/Sparkle.framework" ]]; then
    swift build --target DayreedUpdate
  fi
  compile_module DayreedUpdate -F "$SPARKLE_DIR" -framework Sparkle
fi
