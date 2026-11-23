#!/bin/bash
# Xcode post-build step. Signs with the stable local identity when it exists so macOS
# keeps Screen Recording permission across rebuilds; falls back to ad-hoc signing.
set -euo pipefail
APP="${1:-$CODESIGNING_FOLDER_PATH}"
ENTITLEMENTS="$(dirname "$0")/../ClearShot/Resources/ClearShot.entitlements"
IDENTITY="ClearShot Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  SIGN="$IDENTITY"
else
  SIGN="-"
fi
codesign --force --deep --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" --sign "$SIGN" "$APP"
echo "Signed $(basename "$APP") with: $SIGN"
