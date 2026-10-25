#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/build-app.sh"
open "$SCRIPT_DIR/../build/Mac Status.app"
