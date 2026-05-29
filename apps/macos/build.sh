#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="DesktopFootball"

echo "Building ${APP_NAME}..."
swift build -c release

echo "Packaging .app bundle..."
rm -rf "dist/${APP_NAME}.app"
mkdir -p "dist/${APP_NAME}.app/Contents/MacOS"
mkdir -p "dist/${APP_NAME}.app/Contents/Resources"

cp ".build/release/${APP_NAME}" "dist/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "dist/${APP_NAME}.app/Contents/Info.plist"

echo "Done: dist/${APP_NAME}.app"

if [[ "$1" == "--open" ]]; then
    pkill "${APP_NAME}" 2>/dev/null || true
    sleep 0.5
    open "dist/${APP_NAME}.app"
    echo "Launched."
fi

if [[ "$1" == "--release" ]]; then
    echo ""
    echo "=== Ad-hoc signing ==="
    codesign --force --deep --sign - "dist/${APP_NAME}.app"
    codesign -dvv "dist/${APP_NAME}.app" 2>&1 | grep -E '(Signature|Identifier)'

    echo ""
    echo "=== Creating DMG ==="
    rm -f "dist/${APP_NAME}.dmg"
    hdiutil create -volname "Desktop Football" \
        -srcfolder "dist/${APP_NAME}.app" \
        -ov -format UDZO \
        "dist/${APP_NAME}.dmg"

    echo ""
    ls -lh "dist/${APP_NAME}.dmg"
    echo ""
    echo "To release:  gh release create <tag> dist/${APP_NAME}.dmg --title \"Desktop Football\" --notes \"...\""
fi
