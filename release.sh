#!/bin/sh
# Usage: ./release.sh
#   Build, sign with Developer ID (hardened runtime), notarize, staple,
#   then publish build/Launcher-<version>.zip as GitLab release v<version>.
#   Notarizes with the App Store Connect API key set up by `asc login` (~/.asc).
set -e
cd "$(dirname "$0")"

ASC_CONFIG="$HOME/.asc/config.json"
KEY_ID=$(plutil -extract keyId raw "$ASC_CONFIG")
ISSUER_ID=$(plutil -extract issuerId raw "$ASC_CONFIG")
NOTARY_AUTH="--key $HOME/.asc/AuthKey_$KEY_ID.p8 --key-id $KEY_ID --issuer $ISSUER_ID"
IDENTITY="${IDENTITY:-Developer ID Application}"
APP=build/Launcher.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
TAG="v$VERSION"
ZIP="build/Launcher-$VERSION.zip"

./build.sh
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
# A rejected submission still exits 0, so check the status
# shellcheck disable=SC2086
RESULT=$(xcrun notarytool submit "$ZIP" $NOTARY_AUTH --wait --output-format json)
STATUS=$(echo "$RESULT" | plutil -extract status raw -)
if [ "$STATUS" != "Accepted" ]; then
    echo "Notarization ended as $STATUS: $RESULT" >&2
    exit 1
fi
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

# Re-zip so the uploaded archive contains the stapled ticket
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

glab release create "$TAG" "$ZIP" --name "Launcher $VERSION" --ref "$(git rev-parse HEAD)" \
    --notes "Notarized build for macOS 13+. Unzip and move Launcher.app to /Applications."
echo "Released $TAG"
