#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BUILD="$PWD/build"
APP="$BUILD/PHP Switcher.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macosx14.0 \
  -module-cache-path "$BUILD/module-cache" Sources/*.swift \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$APP/Contents/MacOS/PHPSwitcher"
cp Resources/install_php.py "$APP/Contents/Resources/"
cp -R Resources/en.lproj "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
/usr/bin/codesign --force --deep --sign - "$APP"
echo "$APP"
