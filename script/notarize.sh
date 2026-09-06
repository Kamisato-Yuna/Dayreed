#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT_DIR/script/release.env" ]]; then
    source "$ROOT_DIR/script/release.env"
fi
: "${SIGN_ID:?Set an existing Developer ID Application identity in script/release.env}"
: "${NOTARY_PROFILE:?Set an existing notarytool Keychain profile in script/release.env}"
if [[ "$SIGN_ID" != 'Developer ID Application: '* ]]; then
    echo "Distribution requires a Developer ID Application identity." >&2
    exit 1
fi
"$ROOT_DIR/script/build_app.sh" release
APP_PATH="$ROOT_DIR/build/release/Dayreed.app"
RUN_DIR="$(mktemp -d "$ROOT_DIR/build/notary.XXXXXX")"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP_PATH/Contents/Helpers/dayreed"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$RUN_DIR/submission.zip"
xcrun notarytool submit "$RUN_DIR/submission.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$RUN_DIR/notary-result.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("Notarization:",r.get("status")); sys.exit(0 if r.get("status")=="Accepted" else 1)' "$RUN_DIR/notary-result.json"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$RUN_DIR/Dayreed-$VERSION.zip"
echo "Notarized archive: $RUN_DIR/Dayreed-$VERSION.zip"
echo "No Git tag or GitHub Release was created."
