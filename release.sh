#!/bin/sh
# Usage: ./release.sh
#   Build, sign with Developer ID (hardened runtime), notarize, staple,
#   then publish build/Launcher-<version>.zip as GitHub release v<version> and
#   update the cask in the Homebrew tap (monk-studio/homebrew-tap, checked out
#   next to this repo, or at $TAP).
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
TAP="${TAP:-../homebrew-tap}"

if [ ! -f "$TAP/Casks/launcher.rb" ]; then
    echo "No tap at $TAP: git clone git@github.com:monk-studio/homebrew-tap.git $TAP" >&2
    exit 1
fi
git -C "$TAP" pull -q --ff-only
git push

./build.sh
codesign --force --options runtime --timestamp --entitlements Launcher.entitlements --sign "$IDENTITY" "$APP"
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

gh release create "$TAG" "$ZIP" --target "$(git rev-parse HEAD)" --title "Launcher $VERSION" \
    --notes "Notarized build for macOS 13+. Unzip and move Launcher.app to /Applications."

# Update the cask in the tap and publish it
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/launcher.rb"
git -C "$TAP" commit -q -m "Update launcher to $VERSION" Casks/launcher.rb
git -C "$TAP" push -q
echo "Released $TAG"
