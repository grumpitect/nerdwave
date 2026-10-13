#!/bin/zsh
# Runs the tests, builds Nerdwave.app, and installs it to ~/Applications (quitting a running copy first).
#
# Usage:
#   ./build.sh
#   SIGN_IDENTITY="Nerdwave Signing" ./build.sh
#
# Set SIGN_IDENTITY to a code signing identity (a free self-signed certificate is enough) so macOS
# keeps Nerdwave's folder permissions across rebuilds. Without it the app is signed ad hoc, and macOS
# may ask for (or silently drop) access to your music folder after every rebuild.
set -euo pipefail
cd "${0:A:h}"

SCRATCH="${TMPDIR:-/tmp}/nerdwave-swiftpm"
swift test --scratch-path "$SCRATCH" 2>&1 | tail -3
swift build -c release --product App --scratch-path "$SCRATCH" 2>&1 | grep -E "error|Build complete" | tail -2

BUILD="${TMPDIR:-/tmp}/nerdwave-build"
APP="$BUILD/Nerdwave.app"
rm -rf "$BUILD" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SCRATCH/release/App" "$APP/Contents/MacOS/Nerdwave"
cp Info.plist "$APP/Contents/Info.plist"
# Build number = number of commits, so every installed build is unique and increasing (repo files untouched).
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 0)" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null
fi

mkdir -p ~/Applications
pkill -x "Nerdwave" 2>/dev/null || true
rm -rf ~/Applications/"Nerdwave.app"
cp -R "$APP" ~/Applications/
echo "installed: ~/Applications/Nerdwave.app"
