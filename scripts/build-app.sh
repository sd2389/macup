#!/bin/bash
# Builds build/MacUp.app from the SwiftPM target, for local use until the
# Xcode project exists. The bundle is ad-hoc signed, so it runs on this Mac only.
# Release by default; `debug` adds developer tooling such as --snapshot-dir.
#
#   scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${1:-release}"
swift build -c "$configuration" --product MacUpApp --force-resolved-versions
# The app schedules this copy of the CLI, so the two can never be different
# versions of MacUp.
swift build -c "$configuration" --product macup --force-resolved-versions
binary="$(swift build -c "$configuration" --show-bin-path)/MacUpApp"
cli="$(swift build -c "$configuration" --show-bin-path)/macup"

app="build/MacUp.app"
rm -rf "$app"
# The icon is drawn from source rather than committed as a binary blob.
swift scripts/make-icon.swift >/dev/null

mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/MacUp"
cp "$cli" "$app/Contents/Helpers/macup"
cp Apps/MacUpApp/MacUpApp/Resources/Info.plist "$app/Contents/Info.plist"
# MacUpCore holds the version. Writing it into the bundle here means the app
# and the CLI beside it can never claim to be different versions of MacUp.
version="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/MacUpCore/MacUp.swift)"
if [[ -z "$version" ]]; then
    echo "error: could not read MacUp.version from Sources/MacUpCore/MacUp.swift" >&2
    exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
cp build/MacUp.icns "$app/Contents/Resources/MacUp.icns"

# Ad-hoc, because there is no Developer ID here to sign with. The identifier is
# pinned to the bundle identifier so the signature cannot drift from it, but an
# ad-hoc signature still carries no team identifier, so macOS has no developer
# to attribute the app to and will not grant it camera access — and the
# signature's hash changes on every build, so it could not remember a decision
# even if it made one. The app says so where someone meets it; see
# Apps/MacUpApp/MacUpApp/App/CameraReadiness.swift.
codesign --force --sign - --identifier dev.macup.MacUp "$app"
echo "$app"
