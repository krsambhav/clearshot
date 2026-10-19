#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sources=()
while IFS= read -r source; do
  [[ "$source" == "ClearShot/App/AppDelegate.swift" ]] || sources+=("$source")
done < <(rg --files ClearShot -g '*.swift')
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
  "${sources[@]}" Tests/EditorRegression.swift -o "$work/editor-tests"
"$work/editor-tests"
