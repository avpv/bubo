#!/bin/bash
# Build Bubo.app from SPM sources
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

CONFIG="${1:-release}"
echo "Building Bubo ($CONFIG)..."

swift build -c "$CONFIG"
BIN_PATH=$(swift build -c "$CONFIG" --show-bin-path)

APP="$PROJECT_DIR/Bubo.app/Contents"

# Clean previous build
rm -rf "$PROJECT_DIR/Bubo.app"

# Create bundle structure
mkdir -p "$APP/MacOS" "$APP/Resources"

# Copy binary
cp "$BIN_PATH/Bubo" "$APP/MacOS/"

# Copy resources
cp "$PROJECT_DIR/Bubo/Resources/AppIcon.icns" "$APP/Resources/"

# Copy SPM resource bundle (needed for Bundle.module / Bundle.safeModule)
BUNDLE_NAME="Bubo_Bubo.bundle"
if [ -d "$BIN_PATH/$BUNDLE_NAME" ]; then
    cp -R "$BIN_PATH/$BUNDLE_NAME" "$APP/Resources/"
    echo "Copied SPM resource bundle"
else
    echo "Warning: SPM resource bundle not found at $BIN_PATH/$BUNDLE_NAME"
    echo "Menu bar icon will fall back to SF Symbol"
fi

# Create Info.plist
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ru</string>
  <key>CFBundleExecutable</key>
  <string>Bubo</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleIdentifier</key>
  <string>com.avpv.Bubo</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Bubo</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <false/>
  </dict>
  <key>NSCalendarsUsageDescription</key>
  <string>Bubo needs access to your calendars to show meeting reminders from accounts configured in the Calendar app.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Bubo needs access to your calendars to show meeting reminders from accounts configured in the Calendar app.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so the app runs locally without xattr workaround
codesign --force --deep --entitlements "$PROJECT_DIR/Bubo/Bubo.entitlements" --sign - "$PROJECT_DIR/Bubo.app"

echo ""
echo "Built: $PROJECT_DIR/Bubo.app"
echo ""
echo "To install:"
echo "  cp -R Bubo.app /Applications/"
echo "  open /Applications/Bubo.app"
