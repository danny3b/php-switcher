#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -n "$(git status --porcelain)" ]; then
  echo 'Commit the release source before preparing artifacts.' >&2
  exit 1
fi
REVISION=$(git rev-parse HEAD)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo 'A semantic release version and an integer build number are required.' >&2
  exit 1
fi
SPARKLE_ROOT="$(bash Scripts/fetch_sparkle.sh)"
PUBLIC_KEY=$("$SPARKLE_ROOT/bin/generate_keys" --account pl.daniel.php-switcher -p)
EXPECTED_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)
if [ "$PUBLIC_KEY" != "$EXPECTED_KEY" ]; then
  echo 'The signing key in Keychain does not match SUPublicEDKey. Restore the original key.' >&2
  exit 1
fi
bash build.sh
APP="$PWD/build/PHP Switcher.app"
RELEASE_DIR="$PWD/build/releases/$VERSION"
mkdir -p "$RELEASE_DIR"
ARCHIVE="$RELEASE_DIR/PHP-Switcher-$VERSION-arm64.zip"
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
# Generate from the ZIP only; the manual installer must not become a second
# appcast entry for the same build when preparing a release again.
FEED_DIR=$(mktemp -d "$PWD/build/appcast.XXXXXX")
trap 'rm -rf "$FEED_DIR"' EXIT
cp "$ARCHIVE" "$FEED_DIR/"
"$SPARKLE_ROOT/bin/generate_appcast" --account pl.daniel.php-switcher \
  --download-url-prefix "https://github.com/danny3b/php-switcher/releases/download/v$VERSION/" \
  --link 'https://github.com/danny3b/php-switcher/releases' \
  --maximum-deltas 0 "$FEED_DIR"
mv "$FEED_DIR/appcast.xml" "$RELEASE_DIR/appcast.xml"
"$SPARKLE_ROOT/bin/sign_update" --account pl.daniel.php-switcher "$RELEASE_DIR/appcast.xml"
bash Scripts/create_dmg.sh "$APP" "$RELEASE_DIR/PHP-Switcher-$VERSION-arm64.dmg"
if [ "$REVISION" != "$(git rev-parse HEAD)" ] || [ -n "$(git status --porcelain)" ]; then
  echo 'Source changed during packaging. Prepare the release again.' >&2
  exit 1
fi
printf '%s\n' "$REVISION" > "$RELEASE_DIR/SOURCE_REVISION"
(cd "$RELEASE_DIR" && shasum -a 256 "PHP-Switcher-$VERSION-arm64.zip" "PHP-Switcher-$VERSION-arm64.dmg" appcast.xml > SHA256SUMS)
printf 'Prepared release %s (build %s): %s\n' "$VERSION" "$BUILD_NUMBER" "$RELEASE_DIR"
