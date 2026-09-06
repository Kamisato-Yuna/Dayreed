#!/usr/bin/env bash
# Explicit inside-out Sparkle signing, following the official sandboxing guide.
set -euo pipefail
[[ $# == 2 ]] || { echo "usage: $0 <Dayreed.app> <-|Developer ID Application identity>" >&2; exit 2; }
APP_PATH="$1"
IDENTITY="$2"
FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != - ]]; then
    [[ "$IDENTITY" == 'Developer ID Application: '* ]] || { echo 'Expected Developer ID Application.' >&2; exit 2; }
    ARGS+=(--options runtime --timestamp)
fi
# Do not use --deep for signing: Downloader must preserve its own entitlements.
codesign "${ARGS[@]}" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign "${ARGS[@]}" --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign "${ARGS[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
codesign "${ARGS[@]}" "$FRAMEWORK/Versions/B/Updater.app"
codesign "${ARGS[@]}" "$FRAMEWORK"
codesign "${ARGS[@]}" "$APP_PATH/Contents/Helpers/dayreed"
codesign "${ARGS[@]}" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
