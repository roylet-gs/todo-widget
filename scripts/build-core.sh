#!/usr/bin/env bash
# Build the Rust core + CLI and generate Swift bindings / xcframework for the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROFILE="${PROFILE:-release}"
MACOSX_DEPLOYMENT_TARGET=26.0 cargo build --profile "$PROFILE" -p todo-core -p todo-cli
LIBDIR="target/$PROFILE"

GEN="$ROOT/app/Generated"
rm -rf "$GEN" && mkdir -p "$GEN/include" "$ROOT/app/Sources/TodoCore"
cargo run -q -p uniffi-bindgen -- generate "$LIBDIR/libtodo_core.dylib" --language swift --out-dir "$GEN"

# Swift side of the bindings lives in its own SwiftPM target.
mv "$GEN/todo_core.swift" "$ROOT/app/Sources/TodoCore/todo_core.swift"
mv "$GEN/todo_coreFFI.h" "$GEN/include/"
mv "$GEN/todo_coreFFI.modulemap" "$GEN/include/module.modulemap"

rm -rf "$GEN/TodoCoreFFI.xcframework"
xcodebuild -quiet -create-xcframework \
  -library "$LIBDIR/libtodo_core.a" -headers "$GEN/include" \
  -output "$GEN/TodoCoreFFI.xcframework"
echo "core built: $GEN/TodoCoreFFI.xcframework"
