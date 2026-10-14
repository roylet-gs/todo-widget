#!/usr/bin/env bash
# Build the Rust core + CLI and generate Swift bindings / xcframework for the app.
#   UNIVERSAL=1  build arm64 + x86_64 and lipo them (release builds for distribution)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROFILE="${PROFILE:-release}"
export MACOSX_DEPLOYMENT_TARGET=26.0
TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  for t in "${TARGETS[@]}"; do
    cargo build --profile "$PROFILE" --target "$t" -p todo-core -p todo-cli
  done
  LIBDIR="target/universal/$PROFILE"
  mkdir -p "$LIBDIR"
  lipo -create -output "$LIBDIR/libtodo_core.a" target/{aarch64,x86_64}-apple-darwin/"$PROFILE"/libtodo_core.a
  lipo -create -output "$LIBDIR/todo" target/{aarch64,x86_64}-apple-darwin/"$PROFILE"/todo
  # Binding metadata is architecture-independent; read it from one slice.
  META_LIB="target/aarch64-apple-darwin/$PROFILE/libtodo_core.dylib"
else
  cargo build --profile "$PROFILE" -p todo-core -p todo-cli
  LIBDIR="target/$PROFILE"
  META_LIB="$LIBDIR/libtodo_core.dylib"
fi

GEN="$ROOT/app/Generated"
rm -rf "$GEN" && mkdir -p "$GEN/include" "$ROOT/app/Sources/TodoCore"
cargo run -q -p uniffi-bindgen -- generate "$META_LIB" --language swift --out-dir "$GEN"

# Swift side of the bindings lives in its own SwiftPM target.
mv "$GEN/todo_core.swift" "$ROOT/app/Sources/TodoCore/todo_core.swift"
mv "$GEN/todo_coreFFI.h" "$GEN/include/"
mv "$GEN/todo_coreFFI.modulemap" "$GEN/include/module.modulemap"

xcodebuild -quiet -create-xcframework \
  -library "$LIBDIR/libtodo_core.a" -headers "$GEN/include" \
  -output "$GEN/TodoCoreFFI.xcframework"
echo "$LIBDIR" > "$GEN/libdir"
echo "core built: $GEN/TodoCoreFFI.xcframework ($LIBDIR)"
