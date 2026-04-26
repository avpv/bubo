#!/bin/bash
# Install Bubo from the latest GitHub pre-release
set -euo pipefail

APP_NAME="Bubo"
REPO="avpv/bubo"
INSTALL_DIR="/Applications"
ASSET="$APP_NAME.dmg"

echo "Installing $APP_NAME (pre-release)..."

# Resolve the newest release tag (including pre-releases) from the public
# Atom feed. The REST API at api.github.com is rate-limited to 60 req/hour
# per anonymous IP and frequently returns 403 on shared/office networks.
LATEST_TAG=$(curl -fsSL "https://github.com/$REPO/releases.atom" \
  | grep -E -o '<id>tag:github\.com,2008:Repository/[0-9]+/[^<]+</id>' \
  | head -1 \
  | sed -E 's#.*Repository/[0-9]+/##; s#</id>##')

if [ -z "$LATEST_TAG" ]; then
  echo "Error: could not determine latest release tag for $REPO" >&2
  exit 1
fi

DMG_URL="https://github.com/$REPO/releases/download/$LATEST_TAG/$ASSET"

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
