#!/bin/bash
# Install Bubo from the latest GitHub pre-release
set -euo pipefail

APP_NAME="Bubo"
REPO="avpv/bubo"
INSTALL_DIR="/Applications"

echo "Installing $APP_NAME (pre-release)..."

# Get the newest release (including pre-releases) DMG URL
DMG_URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases" \
  | grep "browser_download_url.*\.dmg" \
  | head -1 \
  | cut -d '"' -f 4)

if [ -z "$DMG_URL" ]; then
  echo "Error: could not find DMG in any release" >&2
  exit 1
fi

TMP_DMG=$(mktemp /tmp/Bubo.XXXXXX.dmg)
trap 'rm -f "$TMP_DMG"; hdiutil detach "/Volumes/$APP_NAME" 2>/dev/null || true' EXIT

echo "Downloading $DMG_URL..."
curl -fSL -o "$TMP_DMG" "$DMG_URL"

echo "Mounting DMG..."
hdiutil attach "$TMP_DMG" -nobrowse -quiet

echo "Copying to $INSTALL_DIR..."
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "/Volumes/$APP_NAME/$APP_NAME.app" "$INSTALL_DIR/"

echo "Removing quarantine flag..."
xattr -cr "$INSTALL_DIR/$APP_NAME.app"

hdiutil detach "/Volumes/$APP_NAME" -quiet

echo ""
echo "Done! Launching $APP_NAME..."
open "$INSTALL_DIR/$APP_NAME.app"
