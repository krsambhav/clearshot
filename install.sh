#!/bin/bash
# ClearShot installer: downloads the latest release into /Applications and launches it.
#   curl -fsSL https://raw.githubusercontent.com/krsambhav/clearshot/main/install.sh | bash
set -euo pipefail

REPO="krsambhav/clearshot"
URL="https://github.com/$REPO/releases/latest/download/ClearShot.zip"

if [ "$(uname)" != "Darwin" ]; then
  echo "ClearShot is a macOS app." >&2; exit 1
fi
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MAJOR" -lt 15 ]; then
  echo "ClearShot needs macOS 15 or later (you have $(sw_vers -productVersion))." >&2; exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "→ Downloading ClearShot…"
curl -fL --progress-bar "$URL" -o "$TMP/ClearShot.zip"
ditto -x -k "$TMP/ClearShot.zip" "$TMP"

DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

pkill -x ClearShot 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST/ClearShot.app"
ditto "$TMP/ClearShot.app" "$DEST/ClearShot.app"
# Installed via curl, so macOS won't quarantine it; clear the flag anyway in case.
xattr -dr com.apple.quarantine "$DEST/ClearShot.app" 2>/dev/null || true

echo "✓ Installed to $DEST/ClearShot.app"
open "$DEST/ClearShot.app"
echo "  ClearShot is in your menu bar. Allow Screen Recording when asked, then press ⇧⌘2 to copy text from anywhere."
