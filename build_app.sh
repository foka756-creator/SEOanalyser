#!/bin/bash
# Собирает SiteCrawler.app (universal, macOS 15+) и подписывает ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SiteCrawler
APP=SiteCrawler.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SiteCrawler"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SiteCrawler</string>
  <key>CFBundleDisplayName</key><string>SiteCrawler</string>
  <key>CFBundleIdentifier</key><string>local.sitecrawler.app</string>
  <key>CFBundleExecutable</key><string>SiteCrawler</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"
echo "Готово: $(pwd)/$APP"
lipo -archs "$APP/Contents/MacOS/SiteCrawler"
