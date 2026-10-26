#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULE_CACHE="/private/tmp/mac-status-swift-cache"
APP_PATH="$PROJECT_DIR/build/Mac Status.app"
CONTENTS_PATH="$APP_PATH/Contents"
SPARKLE_PATH="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle"
SPARKLE_FRAMEWORK="$SPARKLE_PATH/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"
cd "$PROJECT_DIR"

swift build --configuration release --disable-sandbox --scratch-path .build \
  --cache-path /private/tmp/mac-status-cache --config-path /private/tmp/mac-status-config \
  --security-path /private/tmp/mac-status-security -debug-info-format none \
  -Xswiftc -module-cache-path -Xswiftc "$MODULE_CACHE"

mkdir -p "$CONTENTS_PATH/MacOS" "$CONTENTS_PATH/Resources" "$CONTENTS_PATH/Frameworks"
/usr/bin/install -m 755 "$PROJECT_DIR/.build/release/MacStatus" "$CONTENTS_PATH/MacOS/MacStatus"
/usr/bin/install -m 644 "$PROJECT_DIR/LICENSE" "$CONTENTS_PATH/Resources/LICENSE"
/usr/bin/install -m 644 "$SPARKLE_PATH/LICENSE" "$CONTENTS_PATH/Resources/Sparkle-LICENSE"
# ditto preserves framework symlinks, executable permissions, and signed helpers.
rm -rf "$CONTENTS_PATH/Frameworks/Sparkle.framework"
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$CONTENTS_PATH/Frameworks/Sparkle.framework"

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
  <key>CFBundleShortVersionString</key><string>0.8.0</string>
  <key>CFBundleVersion</key><string>41</string>
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

python3 - "$CONTENTS_PATH/Info.plist" "$PROJECT_DIR/config/updater-public-key.txt" <<'PY'
import base64
import os
from pathlib import Path
import plistlib
import re
import sys

plist_path = Path(sys.argv[1])
public_key = Path(sys.argv[2]).read_text().strip()
if len(base64.b64decode(public_key, validate=True)) != 32:
    raise SystemExit("The Sparkle public key must contain 32 bytes.")
info = plistlib.loads(plist_path.read_bytes())
build_override = os.environ.get("MAC_STATUS_BUILD_NUMBER")
if build_override is not None:
    if not re.fullmatch(r"[0-9]+", build_override) or int(build_override) < 1:
        raise SystemExit("MAC_STATUS_BUILD_NUMBER must be a positive integer.")
    info["CFBundleVersion"] = build_override
info.update({
    "SUFeedURL": "https://github.com/WongyuKoh/Mac-Status/releases/latest/download/appcast.xml",
    "SUPublicEDKey": public_key,
    "SUEnableAutomaticChecks": True,
    "SUAutomaticallyUpdate": False,
    "SUScheduledCheckInterval": 86400,
    "SUEnableSystemProfiling": False,
    "SUVerifyUpdateBeforeExtraction": True,
    "SURequireSignedFeed": True,
    "SUSignedFeedFailureExpirationInterval": 0,
})
plist_path.write_bytes(plistlib.dumps(info, sort_keys=False))
PY

xcrun swift -module-cache-path "$MODULE_CACHE" "$SCRIPT_DIR/make-icon.swift" "$CONTENTS_PATH/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$CONTENTS_PATH/Info.plist"
# Sparkle's nested helpers keep their vendor-provided signatures and entitlements.
# --deep is appropriate for verification, not for recursively re-signing helpers.
/usr/bin/codesign --force --sign - --identifier com.kwg.macstatus "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
printf '\n앱 빌드 완료: %s\n' "$APP_PATH"
