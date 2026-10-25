#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULE_CACHE="/private/tmp/mac-status-swift-cache"
APP_PATH="$PROJECT_DIR/build/Mac Status.app"
CONTENTS_PATH="$APP_PATH/Contents"

mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"
cd "$PROJECT_DIR"

swift build --configuration release --disable-sandbox --scratch-path .build \
  --cache-path /private/tmp/mac-status-cache --config-path /private/tmp/mac-status-config \
  --security-path /private/tmp/mac-status-security -debug-info-format none \
  -Xswiftc -module-cache-path -Xswiftc "$MODULE_CACHE"

mkdir -p "$CONTENTS_PATH/MacOS" "$CONTENTS_PATH/Resources"
/usr/bin/install -m 755 "$PROJECT_DIR/.build/release/MacStatus" "$CONTENTS_PATH/MacOS/MacStatus"
/usr/bin/install -m 644 "$PROJECT_DIR/LICENSE" "$CONTENTS_PATH/Resources/LICENSE"

cat > "$CONTENTS_PATH/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mac Status</string>
  <key>CFBundleDisplayName</key><string>Mac Status</string>
  <key>CFBundleExecutable</key><string>MacStatus</string>
  <key>CFBundleIdentifier</key><string>com.kwg.macstatus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.6.4</string>
  <key>CFBundleVersion</key><string>12</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict>
</plist>
PLIST

xcrun swift -module-cache-path "$MODULE_CACHE" "$SCRIPT_DIR/make-icon.swift" "$CONTENTS_PATH/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$CONTENTS_PATH/Info.plist"
/usr/bin/codesign --force --deep --sign - --identifier com.kwg.macstatus "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
printf '\n앱 빌드 완료: %s\n' "$APP_PATH"
