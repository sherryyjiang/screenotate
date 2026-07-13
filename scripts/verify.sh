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
echo "Screenotate verification passed"
