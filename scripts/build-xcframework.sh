#!/usr/bin/env bash
# Build the Rust core as a static XCFramework (iOS device, iOS simulator, macOS).
# The macOS slice exists so `swift test` can exercise the wrapper without a simulator.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
core="$here/../engine-core-rs"
out="$here/ClayzoEngineCore.xcframework"

# A Homebrew rustc on PATH shadows the rustup toolchain, which owns the targets.
export PATH="$HOME/.cargo/bin:$PATH"
export IPHONEOS_DEPLOYMENT_TARGET=16.0
export MACOSX_DEPLOYMENT_TARGET=13.0

targets=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)
rustup target add "${targets[@]}" >/dev/null

libraries=()
for target in "${targets[@]}"; do
  (cd "$core" && cargo rustc --release --lib --crate-type staticlib --target "$target")
  libraries+=(-library "$core/target/$target/release/libclayzo_engine_core.a" -headers "$here/include")
done

rm -rf "$out"
xcodebuild -create-xcframework "${libraries[@]}" -output "$out"
