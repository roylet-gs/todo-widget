#!/usr/bin/env bash
# Build the Rust core + CLI and generate Swift bindings / xcframework for the app.
#   UNIVERSAL=1  build arm64 + x86_64 and lipo them (release builds for distribution)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROFILE="${PROFILE:-release}"
# Cargo's output folder for the built-in `dev` profile is `debug`.
PROFILE_DIR="$PROFILE"; [[ "$PROFILE" == "dev" ]] && PROFILE_DIR=debug
export MACOSX_DEPLOYMENT_TARGET=26.0
TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  for t in "${TARGETS[@]}"; do
    cargo build --profile "$PROFILE" --target "$t" -p todo-core -p todo-cli
  done
  LIBDIR="target/universal/$PROFILE_DIR"
  mkdir -p "$LIBDIR"
  lipo -create -output "$LIBDIR/libtodo_core.a" target/{aarch64,x86_64}-apple-darwin/"$PROFILE_DIR"/libtodo_core.a
  lipo -create -output "$LIBDIR/todo" target/{aarch64,x86_64}-apple-darwin/"$PROFILE_DIR"/todo
  # Binding metadata is architecture-independent; read it from one slice.
  META_LIB="target/aarch64-apple-darwin/$PROFILE_DIR/libtodo_core.dylib"
else
  cargo build --profile "$PROFILE" -p todo-core -p todo-cli
  LIBDIR="target/$PROFILE_DIR"
  META_LIB="$LIBDIR/libtodo_core.dylib"
fi

GEN="$ROOT/app/Generated"
rm -rf "$GEN" && mkdir -p "$GEN/include" "$ROOT/app/Sources/TodoWidget/Generated"
cargo run -q -p uniffi-bindgen -- generate "$META_LIB" --language swift --out-dir "$GEN"

# The Swift side of the bindings compiles into the app target (a separate module
# loses the static library's search path in Xcode 26 universal builds).
mv "$GEN/todo_core.swift" "$ROOT/app/Sources/TodoWidget/Generated/todo_core.swift"
mv "$GEN/todo_coreFFI.h" "$GEN/include/"
mv "$GEN/todo_coreFFI.modulemap" "$GEN/include/module.modulemap"

xcodebuild -quiet -create-xcframework \
  -library "$LIBDIR/libtodo_core.a" -headers "$GEN/include" \
  -output "$GEN/TodoCoreFFI.xcframework"
echo "$LIBDIR" > "$GEN/libdir"
echo "core built: $GEN/TodoCoreFFI.xcframework ($LIBDIR)"
