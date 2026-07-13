#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/release"
APP="$ROOT/dist/Screenotate.app"

cd "$ROOT"
swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Screenotate" "$APP/Contents/MacOS/Screenotate"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Assets/screenotate-icon.png" "$APP/Contents/Resources/screenotate-icon.png"
codesign --force --deep --sign - "$APP"
echo "$APP"
