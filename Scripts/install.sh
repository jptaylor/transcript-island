#!/bin/sh
# Builds the Release configuration and installs it as /Applications/Transcript Island.app,
# replacing any copy already there, then launches it.
set -eu

cd "$(dirname "$0")/.."

APP_NAME="Transcript Island"
BUILD_DIR="build"
BUILT_APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"

echo "Building…"
xcodebuild build \
    -project TranscriptIsland.xcodeproj \
    -scheme TranscriptIsland \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_DIR" \
    -allowProvisioningUpdates \
    -quiet

codesign --verify --deep --strict "$BUILT_APP"

echo "Installing to $INSTALLED_APP…"
pkill -x "$APP_NAME" 2>/dev/null || true
mkdir -p "$INSTALLED_APP"
rsync -a --delete "$BUILT_APP/" "$INSTALLED_APP/"

open "$INSTALLED_APP"
echo "Done. Look for the waveform icon in the menu bar."
