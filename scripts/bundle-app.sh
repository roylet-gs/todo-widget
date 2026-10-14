#!/usr/bin/env bash
# Build everything and assemble build/TodoWidget.app (ad-hoc signed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

./scripts/build-core.sh
(cd app && swift build -c release)

APP="$ROOT/build/TodoWidget.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "app/.build/release/TodoWidget" "$APP/Contents/MacOS/TodoWidget"
cp "target/release/todo" "$APP/Contents/MacOS/todo"
cp "app/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" --options runtime "$APP/Contents/MacOS/todo"
codesign --force --sign "${SIGN_IDENTITY:--}" --options runtime "$APP"
echo "built $APP"
