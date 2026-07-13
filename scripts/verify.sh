#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Screenotate.app"

cd "$ROOT"
swift build -c debug
zsh "$ROOT/scripts/package-app.sh" >/dev/null
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
test -x "$APP/Contents/MacOS/Screenotate"
test -f "$APP/Contents/Resources/AppIcon.icns"
test -f "$APP/Contents/Resources/screenotate-icon.png"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")" = "AppIcon"
echo "Screenotate verification passed"
