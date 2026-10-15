#!/bin/bash
# Bumps the patch version, builds a universal Release, commits, tags, pushes and
# publishes a GitHub release with ClearShot.zip (what install.sh downloads).
#   scripts/release.sh "Release notes in markdown"
set -euo pipefail
cd "$(dirname "$0")/.."

NOTES="${1:?usage: scripts/release.sh \"release notes\"}"

OLD=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml)
IFS=. read -r MAJ MIN PAT <<<"$OLD"
VERSION="$MAJ.$MIN.$((PAT + 1))"
BUILD=$((BUILD + 1))

sed -i '' "s/MARKETING_VERSION: \"$OLD\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \"[0-9]*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml

xcodegen generate --quiet
xcodebuild -project ClearShot.xcodeproj -scheme ClearShot -configuration Release -derivedDataPath build -destination "generic/platform=macOS" clean build -quiet

mkdir -p dist
rm -f dist/ClearShot.zip
ditto -c -k --keepParent build/Build/Products/Release/ClearShot.app dist/ClearShot.zip

git add -A
git commit -q -m "ClearShot v$VERSION" -m "$NOTES"
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"

gh release create "v$VERSION" dist/ClearShot.zip --title "ClearShot $VERSION" --notes "$NOTES

**Install**
\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/krsambhav/clearshot/main/install.sh | bash
\`\`\`"
echo "✓ Released v$VERSION"
