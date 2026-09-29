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

# Signed with a real identity when this Mac has one: an Apple Development
# certificate (free with an Apple ID, created in Xcode > Settings > Accounts >
# Manage Certificates) or a Developer ID. That signature names a team, so
# macOS can attribute the app to a developer, ask for camera access, and
# remember the answer across rebuilds. MACUP_SIGNING_IDENTITY picks one
# explicitly (a SHA-1 hash or a name from `security find-identity`).
#
# Otherwise ad-hoc. The identifier is pinned to the bundle identifier so the
# signature cannot drift from it, but an ad-hoc signature carries no team
# identifier, so macOS has no developer to attribute the app to and will not
# grant it camera access — and its hash changes on every build, so it could not
# remember a decision even if it made one. The app says so where someone meets
# it; see Apps/MacUpApp/MacUpApp/App/CameraReadiness.swift.
identity="${MACUP_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/"(Apple Development|Developer ID Application): / { print $2; exit }')"
fi
if [[ -n "$identity" ]]; then
    # The helper first: a bundle's signature covers the code inside it.
    codesign --force --sign "$identity" --identifier dev.macup.cli "$app/Contents/Helpers/macup"
    codesign --force --sign "$identity" --identifier dev.macup.MacUp "$app"
    echo "Signed with identity $identity." >&2
else
    codesign --force --sign - --identifier dev.macup.MacUp "$app"
    echo "Signed ad-hoc: no Apple Development or Developer ID certificate on this Mac, so face match stays off." >&2
fi
echo "$app"
