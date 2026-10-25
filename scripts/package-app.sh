#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="$PROJECT_DIR/build/Mac Status.app"
ARCHIVE_PATH="$PROJECT_DIR/build/Mac-Status.zip"
DMG_PATH="$PROJECT_DIR/build/Mac-Status.dmg"

"$SCRIPT_DIR/build-app.sh"
/usr/bin/ditto --keepParent -c -k --sequesterRsrc "$APP_PATH" "$ARCHIVE_PATH"
DMG_STAGE="$(mktemp -d "$PROJECT_DIR/build/dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGE"' EXIT
/usr/bin/ditto "$APP_PATH" "$DMG_STAGE/Mac Status.app"
ln -s /Applications "$DMG_STAGE/Applications"
/usr/bin/hdiutil create -volname "Mac Status" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH"
python3 "$SCRIPT_DIR/make-appcast.py"
python3 - "$PROJECT_DIR/build" <<'PY'
import hashlib
from pathlib import Path
import sys

output = Path(sys.argv[1])
names = ["Mac-Status.dmg", "Mac-Status.zip", "appcast.xml"]
(output / "SHA256SUMS.txt").write_text("".join(
    hashlib.sha256((output / name).read_bytes()).hexdigest() + "  " + name + "\n"
    for name in names
))
PY
printf '\n패키지 생성 완료: %s\n' "$ARCHIVE_PATH"
printf '설치 이미지 생성 완료: %s\n' "$DMG_PATH"
