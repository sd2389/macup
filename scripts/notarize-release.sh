#!/bin/bash
# Notarizes the release built by scripts/package-release.sh, then staples the
# ticket into the app so it opens without a network connection.
#
#   scripts/notarize-release.sh
#
# What it needs, and never reads from the repository:
#
#   APPLE_API_KEY_ID        App Store Connect key id (for example ABC123XYZ9)
#   APPLE_API_ISSUER_ID     the issuer UUID shown beside the key
#   APPLE_API_KEY_FILE      path to the .p8 private key file
#
# The app must already be signed with a Developer ID Application certificate,
# with the hardened runtime and a secure timestamp: scripts/build-app.sh does
# that whenever such a certificate is present. Apple refuses anything else, so
# this script checks before it uploads rather than after.
#
# Nothing here signs, builds, or publishes. It uploads the zip that already
# exists, waits for Apple's answer, staples it into build/MacUp.app, repacks
# that zip, and rewrites SHA256SUMS so the published checksums match the
# stapled file people download (docs/RELEASE.md).
set -euo pipefail
cd "$(dirname "$0")/.."

out="build/release"
app="build/MacUp.app"
version="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/MacUpCore/MacUp.swift)"
zip="$out/MacUp-$version-macos-universal.zip"

for required in "$app" "$zip" "$out/SHA256SUMS"; do
    if [[ ! -e "$required" ]]; then
        echo "error: $required is missing; run scripts/package-release.sh first" >&2
        exit 1
    fi
done
for variable in APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_KEY_FILE; do
    if [[ -z "${!variable:-}" ]]; then
        echo "error: $variable is not set; see docs/RELEASE.md" >&2
        exit 1
    fi
done
if [[ ! -f "$APPLE_API_KEY_FILE" ]]; then
    echo "error: APPLE_API_KEY_FILE ($APPLE_API_KEY_FILE) is not a file" >&2
    exit 1
fi

# Apple notarizes only Developer ID code with the hardened runtime. Checking
# here turns a confusing rejection minutes later into a clear failure now.
authority="$(codesign --display --verbose=2 "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [[ "$authority" != "Developer ID Application:"* ]]; then
    echo "error: $app is signed by '${authority:-nobody}', which Apple will not notarize." >&2
    echo "Build it with a Developer ID Application certificate on the keychain." >&2
    exit 1
fi
if ! codesign --display --verbose=2 "$app" 2>&1 | grep -q "flags=.*runtime"; then
    echo "error: $app was signed without the hardened runtime, which Apple requires." >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$app"

echo "Submitting $zip to Apple. This usually takes a few minutes."
xcrun notarytool submit "$zip" \
    --key "$APPLE_API_KEY_FILE" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" \
    --wait

# The ticket goes into the app itself, so a copy that is downloaded opens on a
# Mac with no network connection.
xcrun stapler staple "$app"
xcrun stapler validate "$app"

# Repack and re-checksum: the stapled bundle is not the one that was zipped.
rm -f "$zip"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$app" "$zip"
(cd "$out" && shasum -a 256 ./*.tar.gz ./*.zip | sed 's| \./| |' > SHA256SUMS)
cat "$out/SHA256SUMS"

# What macOS itself will say about the downloaded copy, before anyone finds
# out the hard way.
spctl --assess --type execute --verbose=2 "$app"
echo "Notarized and stapled."
