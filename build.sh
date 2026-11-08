#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
XCODE_DEVELOPER="/Applications/Xcode.app/Contents/Developer"

npm --prefix "$ROOT/web" ci
npm --prefix "$ROOT/web" run build
DEVELOPER_DIR="$XCODE_DEVELOPER" "$XCODE_DEVELOPER/usr/bin/xcodebuild" \
  -project "$ROOT/3D Model Viewer.xcodeproj" \
  -scheme "3D Model Viewer" \
  -configuration Release \
  -derivedDataPath "$ROOT/.build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build

print -r -- "Built: $ROOT/.build/DerivedData/Build/Products/Release/3D Model Viewer.app"
