#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
  ClearShot/OCR/TextRecognizer.swift Tests/OCRRegression.swift -o "$work/ocr-tests"
"$work/ocr-tests"
