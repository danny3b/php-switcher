#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-$PWD/build/DevZbik.app}"
INFO="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")
IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")
APP_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO")
BUNDLE_NAME=$(basename "$APP")
ARCHIVE_PREFIX=DevZbik
if [ "$BUNDLE_NAME" = 'PHP Switcher.app' ]; then ARCHIVE_PREFIX=PHP-Switcher; fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ "$IDENTIFIER" != pl.daniel.php-switcher ]; then
  echo 'Expected a versioned DevZbik or legacy PHP Switcher application bundle.' >&2
  exit 1
fi
OUTPUT="${2:-$PWD/build/releases/$VERSION/$ARCHIVE_PREFIX-$VERSION-arm64.dmg}"
if [[ "$OUTPUT" != *.dmg ]]; then
  echo 'The output path must end in .dmg.' >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$APP"
mkdir -p build "$(dirname "$OUTPUT")"
WORK_DIR=$(mktemp -d "$PWD/build/dmg.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir "$WORK_DIR/content"
/usr/bin/ditto "$APP" "$WORK_DIR/content/$BUNDLE_NAME"
ln -s /Applications "$WORK_DIR/content/Applications"
cat > "$WORK_DIR/content/Read Me.txt" <<EOF
Installing $APP_NAME

1. Drag $BUNDLE_NAME onto the Applications folder.
2. Eject this disk image.
3. Open $APP_NAME from Applications.

Requires macOS 14 or later on Apple Silicon.
Application updates are available in Settings.

Created by danny3b
https://github.com/danny3b/php-switcher
EOF
/usr/bin/hdiutil create -volname "$APP_NAME" -srcfolder "$WORK_DIR/content" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 "$WORK_DIR/installer.dmg"
/usr/bin/hdiutil verify "$WORK_DIR/installer.dmg"
mv -f "$WORK_DIR/installer.dmg" "$OUTPUT"
(cd "$(dirname "$OUTPUT")" && shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256")
printf 'Created installer: %s\n' "$OUTPUT"
