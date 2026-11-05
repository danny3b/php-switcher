#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BUILD="$PWD/build"
APP="$BUILD/DevZbik.app"
SPARKLE_ROOT="$(bash Scripts/fetch_sparkle.sh)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macosx14.0 \
  -module-cache-path "$BUILD/module-cache" Sources/*.swift \
  -F "$SPARKLE_ROOT" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework Security -o "$APP/Contents/MacOS/DevZbik"
/usr/bin/ditto "$SPARKLE_ROOT/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE_ROOT/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
cp Resources/install_php.py "$APP/Contents/Resources/"
cp Resources/import_database.py "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
/usr/bin/codesign --force --deep --sign - "$APP"
echo "$APP"
