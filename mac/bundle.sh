#!/bin/bash
# Assemble the SwiftPM executable into a real .app bundle.
#
# Three things a bare `swift build` binary cannot do, all of which this fixes:
#
#   1. No Info.plist, so macOS TCC has nowhere to read NSMicrophoneUsageDescription
#      from and the microphone prompt never appears. No bundle == no voice.
#   2. No bundle identity, so the Screen Recording and Accessibility grants have
#      nothing stable to attach to and are forgotten on every launch.
#   3. SwiftPM links LiveKit's binary xcframeworks but does NOT embed them, so a
#      hand-rolled bundle dies at launch with
#        dyld: Library not loaded: @rpath/LiveKitWebRTC.framework/LiveKitWebRTC
#
# Adapted from the SDK's Cartographer example, which hit all three first.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/CodeCopilot.app"

# --package-path, not a bare `swift build`: without it the build runs in
# whoever's working directory invoked this script, which fails with
# "Could not find Package.swift" for anyone not already sitting in the repo.
swift build --package-path "$ROOT" -c "$CONFIG"
BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)/CodeCopilot"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/CodeCopilot"

for XC in $(find "$ROOT/.build/artifacts" -name '*.xcframework' -maxdepth 3); do
  SLICE="$(find "$XC" -maxdepth 1 -type d -name 'macos-*' | head -1)"
  [ -n "$SLICE" ] || { echo "no macOS slice in $XC" >&2; exit 1; }
  FW="$(find "$SLICE" -maxdepth 1 -type d -name '*.framework' | head -1)"
  cp -R "$FW" "$APP/Contents/Frameworks/"
  echo "  embedded $(basename "$FW")"
done

install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$APP/Contents/MacOS/CodeCopilot" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Code Copilot</string>
  <key>CFBundleDisplayName</key>       <string>Code Copilot</string>
  <key>CFBundleIdentifier</key>        <string>local.codecopilot</string>
  <key>CFBundleExecutable</key>        <string>CodeCopilot</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Code Copilot listens so you can talk to it about your code.</string>
</dict>
</plist>
PLIST

# Sign with the stable local identity if it exists, ad-hoc otherwise.
#
# This choice decides whether your permissions survive a rebuild. An ad-hoc
# signature has no identity, so the designated requirement falls back to the
# binary's cdhash — which changes every time the code does, silently
# invalidating the Screen Recording and Accessibility grants. The app stays
# ticked in System Settings and is treated as a different app regardless.
#
# With the self-signed identity the requirement becomes
#   identifier "local.codecopilot" and certificate leaf = H"…"
# which is stable, so the grants are given once and stay given.
#
# Run ./make-identity.sh to create it. Reversible: delete "Code Copilot Local"
# in Keychain Access.
IDENTITY="Code Copilot Local"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" --deep "$APP" >/dev/null 2>&1 \
    && echo "  signed with $IDENTITY (permissions persist across rebuilds)" \
    || echo "  (signing with $IDENTITY failed)"
else
  codesign --force --sign - --deep "$APP" >/dev/null 2>&1 || true
  echo "  signed ad-hoc — run ./make-identity.sh so permissions survive rebuilds"
fi

echo "built $APP"
