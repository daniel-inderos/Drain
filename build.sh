#!/bin/zsh
# Builds Drain.app next to this script.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=Drain.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Drain "$APP/Contents/MacOS/Drain"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Drain</string>
  <key>CFBundleDisplayName</key><string>Drain</string>
  <key>CFBundleIdentifier</key><string>local.drain.menubar</string>
  <key>CFBundleExecutable</key><string>Drain</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Drain asks apps to quit the same way ⌘Q does, so they close cleanly and keep their state.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $(pwd)/$APP"

# ./build.sh --install  copies the app to /Applications and restarts it there.
if [[ "$1" == "--install" ]]; then
  pkill -x Drain || true
  rm -rf /Applications/Drain.app
  ditto "$APP" /Applications/Drain.app
  open /Applications/Drain.app
  echo "Installed /Applications/Drain.app"
fi
