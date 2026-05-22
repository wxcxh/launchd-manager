#!/bin/zsh

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
BINARY="$BUILD_DIR/launchd_manager"
SOURCE="$SCRIPT_DIR/LaunchdManager.swift"

mkdir -p "$BUILD_DIR" || exit 1

if [ ! -x "$BINARY" ] || [ "$SOURCE" -nt "$BINARY" ]; then
  xcrun swiftc \
    -parse-as-library \
    -target arm64-apple-macos12.0 \
    -framework SwiftUI \
    -framework AppKit \
    "$SOURCE" \
    -o "$BINARY" || exit 1
fi

exec "$BINARY"
