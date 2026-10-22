#!/bin/bash
# Builds the Rust FFI shim for iOS (device + Apple-Silicon simulator) and
# repackages GassPairFFI.xcframework. Run this whenever rust/ changes.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || echo /Applications/Xcode.app/Contents/Developer)}"
# Keep in sync with project.yml (deploymentTarget).
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT/rust"

echo "==> Building Rust static libs (release)"
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim

echo "==> Repackaging GassPairFFI.xcframework"
rm -rf "$ROOT/GassPairFFI.xcframework"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libgasspair_ffi.a -headers include \
  -library target/aarch64-apple-ios-sim/release/libgasspair_ffi.a -headers include \
  -output "$ROOT/GassPairFFI.xcframework"

echo "==> Done. (Re)generate the project with: xcodegen generate"
