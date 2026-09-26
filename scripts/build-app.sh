#!/bin/bash
# Builds build/MacUp.app from the SwiftPM target, for local use until the
# Xcode project exists. The bundle is ad-hoc signed, so it runs on this Mac only.
#
#   scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${1:-debug}"
swift build -c "$configuration" --product MacUpApp
binary="$(swift build -c "$configuration" --show-bin-path)/MacUpApp"

app="build/MacUp.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/MacUp"
cp Apps/MacUpApp/MacUpApp/Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "$app"
