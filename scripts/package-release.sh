#!/bin/bash
# Builds the files a GitHub release publishes, into build/release:
#
#   macup-<version>-macos-universal.tar.gz   the command-line tool
#   MacUp-<version>-macos-universal.zip      the app, with its copy of the CLI
#   SHA256SUMS                               checksums of both
#
# Both are universal (Apple silicon and Intel) release builds from a clean
# tree. Nothing is uploaded; publishing is a separate, deliberate step
# (docs/RELEASE.md). The app is signed with this Mac's Apple Development or
# Developer ID certificate when it has one, and ad-hoc otherwise.
#
#   scripts/package-release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: the working tree has changes; a release is built from a clean checkout" >&2
    exit 1
fi
version="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/MacUpCore/MacUp.swift)"
if [[ -z "$version" ]]; then
    echo "error: could not read MacUp.version from Sources/MacUpCore/MacUp.swift" >&2
    exit 1
fi

out="build/release"
rm -rf "$out"
mkdir -p "$out/cli"

MACUP_UNIVERSAL=1 scripts/build-app.sh release >/dev/null
cli="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/macup"
if [[ "$("$cli" --version)" != "$version" ]]; then
    echo "error: the CLI reports $("$cli" --version), not $version" >&2
    exit 1
fi
lipo "$cli" -verify_arch arm64 x86_64

cp "$cli" LICENSE "$out/cli/"
tar -C "$out/cli" -czf "$out/macup-$version-macos-universal.tar.gz" macup LICENSE
ditto -c -k --sequesterRsrc --keepParent build/MacUp.app "$out/MacUp-$version-macos-universal.zip"
rm -rf "$out/cli"

(cd "$out" && shasum -a 256 ./*.tar.gz ./*.zip | sed 's| \./| |' > SHA256SUMS)
cat "$out/SHA256SUMS"
