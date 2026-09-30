#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

echo "🔨 Building SynapsMac binary..."
swift build -c release

BIN_PATH="$DIR/.build/release/SynapsMac"
APP_BUNDLE="$DIR/SynapsMac.app"

echo "📦 Creating SynapsMac.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/SynapsMac"
chmod +x "$APP_BUNDLE/Contents/MacOS/SynapsMac"

cat << 'EOF' > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SynapsMac</string>
    <key>CFBundleIdentifier</key>
    <string>com.synaps.mac</string>
    <key>CFBundleName</key>
    <string>Synaps</string>
    <key>CFBundleDisplayName</key>
    <string>Synaps</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSCameraUsageDescription</key>
    <string>Synaps accesses connected iOS devices to ingest media.</string>
</dict>
</plist>
EOF

echo "✨ SynapsMac.app created successfully at: $APP_BUNDLE"
