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
# Nothing here signs, builds, or publishes. It uploads the app zip that already
# exists, waits for Apple's answer, staples it into build/MacUp.app, repacks
# that zip, and rewrites SHA256SUMS so the published checksums match the
# stapled file people download (docs/RELEASE.md).
#
# The command-line tool is submitted too, because it is downloaded on its own
# and a release that says "notarized" has to mean both files. A bare Mach-O
# cannot carry a stapled ticket, so what the tarball ships is the Developer ID
# signature and the hardened runtime; macOS checks the notarization online the
# first time someone runs a downloaded copy.
set -euo pipefail
cd "$(dirname "$0")/.."

out="build/release"
app="build/MacUp.app"
version="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/MacUpCore/MacUp.swift)"
zip="$out/MacUp-$version-macos-universal.zip"
cli="$app/Contents/Helpers/macup"
tarball="$out/macup-$version-macos-universal.tar.gz"

for required in "$app" "$zip" "$tarball" "$out/SHA256SUMS"; do
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
# here turns a confusing rejection minutes later into a clear failure now, and
# it checks both published files: the app, and the tool that ships on its own.
for signed in "$app" "$cli"; do
    authority="$(codesign --display --verbose=2 "$signed" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    if [[ "$authority" != "Developer ID Application:"* ]]; then
        echo "error: $signed is signed by '${authority:-nobody}', which Apple will not notarize." >&2
        echo "Build it with a Developer ID Application certificate on the keychain." >&2
        exit 1
    fi
    if ! codesign --display --verbose=2 "$signed" 2>&1 | grep -q "flags=.*runtime"; then
        echo "error: $signed was signed without the hardened runtime, which Apple requires." >&2
        exit 1
    fi
done
codesign --verify --deep --strict --verbose=2 "$app"
codesign --verify --strict --verbose=2 "$cli"

submit() {
    echo "Submitting $1 to Apple. This usually takes a few minutes."
    xcrun notarytool submit "$1" \
        --key "$APPLE_API_KEY_FILE" \
        --key-id "$APPLE_API_KEY_ID" \
        --issuer "$APPLE_API_ISSUER_ID" \
        --wait
}

submit "$zip"

# The tool goes up in a zip of its own, which is how notarytool accepts a bare
# executable. The zip is a carrier and is not published; the tarball that is
# published holds the same signed binary.
cli_zip="build/macup-notarize.zip"
rm -f "$cli_zip"
ditto -c -k --norsrc --noextattr --noacl "$cli" "$cli_zip"
submit "$cli_zip"
rm -f "$cli_zip"

# The ticket goes into the app itself, so a copy that is downloaded opens on a
# Mac with no network connection.
xcrun stapler staple "$app"
xcrun stapler validate "$app"

# Repack and re-checksum: the stapled bundle is not the one that was zipped.
rm -f "$zip"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$app" "$zip"
(cd "$out" && shasum -a 256 ./*.tar.gz ./*.zip | sed 's| \./| |' > SHA256SUMS)
cat "$out/SHA256SUMS"

# What macOS itself will say about the downloaded copies, before anyone finds
# out the hard way. The tool is assessed as an unstapled executable: Gatekeeper
# looks its notarization up online, which is the only way a bare Mach-O can be
# checked.
spctl --assess --type execute --verbose=2 "$app"
# The published tool, as it comes out of the tarball people download. Its
# notarization is looked up online, so this needs a network connection; a
# failure here is reported, not fatal, because the signature is what the file
# itself carries.
check="build/cli-check"
rm -rf "$check"
mkdir -p "$check"
tar -xzf "$tarball" -C "$check"
spctl --assess --type execute --verbose=2 "$check/macup" \
    || echo "note: Gatekeeper could not confirm the tool; its notarization is checked online." >&2
rm -rf "$check"
echo "App notarized and stapled. Tool notarized (checked online; a bare executable cannot be stapled)."
