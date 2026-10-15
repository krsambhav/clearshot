#!/bin/bash
# Builds a Release copy, installs it to /Applications and relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null && xcodegen generate --quiet
xcodebuild -project ClearShot.xcodeproj -scheme ClearShot -configuration Release -derivedDataPath build build -quiet
pkill -x ClearShot 2>/dev/null || true
sleep 0.5
rm -rf /Applications/ClearShot.app
cp -R build/Build/Products/Release/ClearShot.app /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/ClearShot.app
open /Applications/ClearShot.app
echo "✓ Installed and launched /Applications/ClearShot.app"
