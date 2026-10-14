#!/usr/bin/env bash
# Build everything and assemble build/TodoWidget.app (ad-hoc signed unless SIGN_IDENTITY is set).
#   UNIVERSAL=1  arm64 + x86_64
#   VERSION=x.y.z  stamp this version (default: workspace version in Cargo.toml)
#   ZIP=1  also write build/TodoWidget-v$VERSION.zip for release
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)}"

./scripts/build-core.sh
LIBDIR="$(cat app/Generated/libdir)"

SWIFT_ARGS=(-c release)
[[ "${UNIVERSAL:-0}" == "1" ]] && SWIFT_ARGS+=(--arch arm64 --arch x86_64)
(cd app && swift build "${SWIFT_ARGS[@]}")
APPBIN="$(cd app && swift build "${SWIFT_ARGS[@]}" --show-bin-path)/TodoWidget"

APP="$ROOT/build/TodoWidget.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$APPBIN" "$APP/Contents/MacOS/TodoWidget"
cp "$LIBDIR/todo" "$APP/Contents/MacOS/todo"
cp "app/Resources/Info.plist" "$APP/Contents/Info.plist"
# Liquid Glass icon (edit app/Resources/AppIcon.icon in Icon Composer): Assets.car plus an AppIcon.icns fallback.
xcrun actool "$ROOT/app/Resources/AppIcon.icon" --compile "$APP/Contents/Resources" --app-icon AppIcon \
  --platform macosx --target-device mac --minimum-deployment-target 26.0 \
  --output-partial-info-plist "$ROOT/build/AppIcon-partial.plist" >/dev/null
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" --options runtime "$APP/Contents/MacOS/todo"
codesign --force --sign "${SIGN_IDENTITY:--}" --options runtime "$APP"
echo "built $APP (v$VERSION)"

if [[ "${ZIP:-0}" == "1" ]]; then
  ZIPFILE="$ROOT/build/TodoWidget-v$VERSION.zip"
  rm -f "$ZIPFILE"
  ditto -c -k --keepParent "$APP" "$ZIPFILE"
  echo "zipped $ZIPFILE"
fi
