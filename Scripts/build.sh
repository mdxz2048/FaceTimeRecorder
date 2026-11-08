#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/opt/homebrew/bin:$PATH"
IDENTITY="${FR_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
fi
[ -z "$IDENTITY" ] && IDENTITY="-"
xcodegen generate
xcodebuild -project FaceTimeRecorder.xcodeproj \
  -scheme FaceTimeRecorder -configuration "${1:-Debug}" \
  -derivedDataPath build CODE_SIGN_IDENTITY="$IDENTITY" build
