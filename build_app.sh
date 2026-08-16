#!/bin/zsh
# PhotoAgent.app 번들 빌드 스크립트
set -euo pipefail
cd "$(dirname "$0")"

echo "==> swift build -c release"
swift build -c release

APP="dist/PhotoAgent.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/PhotoAgent "$APP/Contents/MacOS/PhotoAgent"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> codesign (ad-hoc)"
codesign --force --sign - "$APP"

echo "==> 완료: $APP"
