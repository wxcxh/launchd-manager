#!/bin/zsh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="launchd 定时任务管理.app"
APP_DIR="$ROOT/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILD_DIR="$ROOT/.build"
BINARY="$BUILD_DIR/launchd_manager_app"
SOURCE="$ROOT/LaunchdManager.swift"
ICONSET_DIR="$ROOT/assets/LaunchdManager.iconset"
ICON_FILE="$RESOURCES_DIR/LaunchdManager.icns"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$BUILD_DIR"

/usr/bin/env python3 "$ROOT/scripts/generate_launchd_manager_icon.py"
iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"

xcrun swiftc \
  -parse-as-library \
  -target arm64-apple-macos12.0 \
  -framework SwiftUI \
  -framework AppKit \
  "$SOURCE" \
  -o "$BINARY"

cp "$BINARY" "$MACOS_DIR/launchd-manager"
chmod +x "$MACOS_DIR/launchd-manager"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>launchd 定时任务管理</string>
  <key>CFBundleExecutable</key>
  <string>launchd-manager</string>
  <key>CFBundleIconFile</key>
  <string>LaunchdManager</string>
  <key>CFBundleIdentifier</key>
  <string>com.kalikyle.launchd-manager</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>launchd 定时任务管理</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

echo "$APP_DIR"
