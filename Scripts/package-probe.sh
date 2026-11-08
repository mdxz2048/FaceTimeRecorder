#!/bin/zsh
set -euo pipefail

# Wrap the AudioProbe command-line binary in a minimal .app so LaunchServices
# can attribute the audio-capture TCC prompt to a bundle with a usage string.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-Release}"
BUILD_DIR="$ROOT/build"
OUT="$ROOT/build/AudioProbe.app"

# Prefer a stable Apple Development identity so the audio-capture TCC grant
# survives rebuilds. Fall back to ad-hoc only when no identity exists.
IDENTITY="${FR_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
fi
[ -z "$IDENTITY" ] && IDENTITY="-"

cd "$ROOT"
xcodegen generate >/dev/null
xcodebuild -project FaceTimeRecorder.xcodeproj -scheme AudioProbe \
  -configuration "$CONFIG" -derivedDataPath "$BUILD_DIR" build CODE_SIGN_IDENTITY=- >/dev/null

BIN="$BUILD_DIR/Build/Products/$CONFIG/AudioProbe"
test -x "$BIN"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp "$BIN" "$OUT/Contents/MacOS/AudioProbe"
cp "$ROOT/Resources/Info-Probe.plist" "$OUT/Contents/Info.plist"
codesign --force --deep --sign "$IDENTITY" --timestamp=none \
  --entitlements "$ROOT/Resources/FaceTimeRecorder.entitlements" "$OUT" >/dev/null
echo "signed with: $IDENTITY"
echo "$OUT"
