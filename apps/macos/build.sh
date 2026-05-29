#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building Desktop Football..."
swift build -c release

echo "Packaging .app bundle..."
rm -rf dist/DesktopFootball.app
mkdir -p dist/DesktopFootball.app/Contents/MacOS
mkdir -p dist/DesktopFootball.app/Contents/Resources

cp .build/release/DesktopFootball dist/DesktopFootball.app/Contents/MacOS/DesktopFootball
cp Resources/Info.plist dist/DesktopFootball.app/Contents/Info.plist

echo "Done: dist/DesktopFootball.app"

if [[ "$1" == "--open" ]]; then
    pkill DesktopFootball 2>/dev/null || true
    sleep 0.5
    open dist/DesktopFootball.app
    echo "Launched."
fi
