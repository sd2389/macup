# Release and Distribution

## Development channels

- nightly/internal builds
- alpha
- beta
- stable

## CLI distribution

- GitHub Releases: the tagged source (`vX.Y.Z`).
- Homebrew tap [`sd2389/homebrew-macup`](https://github.com/sd2389/homebrew-macup):
  a formula that builds the tagged source, with dependency downloads in its
  `fetch` phase and an offline build.

```bash
brew install sd2389/macup/macup
macup check
```

To publish a release to the tap, set `url` in `Formula/macup.rb` to the new
tag's tarball and `sha256` to that tarball's `shasum -a 256`, then run
`brew reinstall sd2389/macup/macup` and `brew test sd2389/macup/macup`
before pushing the tap.

## Building a release

`scripts/package-release.sh` builds everything a GitHub release publishes,
from a clean working tree, into `build/release`:

- `macup-<version>-macos-universal.tar.gz`: the command-line tool, for Apple
  silicon and Intel
- `MacUp-<version>-macos-universal.zip`: the app, with its own copy of the CLI
- `SHA256SUMS`

It uploads nothing. Publishing is a separate step: tag the release commit
`vX.Y.Z`, push the tag, then create the GitHub release with those three files
and the version's section of `CHANGELOG.md` as its notes.

Until MacUp has a Developer ID, both downloads are signed ad-hoc and not
notarized. macOS then blocks the first launch of a downloaded copy, and the
README tells people to approve it once in System Settings → Privacy &
Security. Releases stay marked as pre-releases until builds are notarized.

The tarball ships the very `macup` binary the app bundle carries
(`Contents/Helpers/macup`), rather than a second build of the same source, so
both downloads always have the same signature. `scripts/package-release.sh`
verifies that binary on its own with `codesign --verify --strict` before it is
packed: a file that is downloaded on its own has to stand on its own.

## Signing and notarizing

`.github/workflows/release.yml` runs on a `v*` tag: it checks the trust
invariants, runs the tests, checks the tag matches `MacUp.version`, builds the
release files, and publishes them with that version's `CHANGELOG.md` section
as the notes. What it does about signing depends entirely on which secrets the
repository has:

- **No secrets** — the app is ad-hoc signed, the release is published as a
  **pre-release**, and its notes say macOS will block the first launch. This
  is what MacUp has shipped so far.
- **The certificate secrets** — the app and the `macup` binary inside it are
  signed with the Developer ID, with the hardened runtime and a secure
  timestamp, which is what Apple requires of anything it will notarize. The
  tarball ships that same signed binary.
- **The certificate and the App Store Connect key** — both files are submitted
  to Apple. The app's ticket is stapled into the bundle so a downloaded copy
  opens with no network connection, the zip is repacked and `SHA256SUMS`
  rewritten (the stapled bundle is not the one that was zipped), and the
  release is published normally rather than as a pre-release. A bare Mach-O
  cannot carry a stapled ticket, so what the tarball ships is the Developer ID
  signature and the hardened runtime, and macOS checks the tool's notarization
  online the first time a downloaded copy runs. The release notes say exactly
  that, per download, rather than claiming a stapled ticket for a file that
  cannot hold one.

### The secrets to add

Add these in the repository's Settings → Secrets and variables → Actions.
Nothing here ever belongs in the repository itself.

| Secret | What it is |
| --- | --- |
| `MACUP_CERTIFICATE_P12` | The Developer ID Application certificate and its private key, exported from Keychain Access as a `.p12`, then `base64 -i certificate.p12 \| pbcopy` |
| `MACUP_CERTIFICATE_PASSWORD` | The password that `.p12` was exported with |
| `MACUP_SIGNING_IDENTITY` | The identity's full name, for example `Developer ID Application: Your Name (TEAMID)` — `security find-identity -v -p codesigning` prints it |
| `APPLE_API_KEY_P8` | An App Store Connect API key with the Developer role, downloaded once as `AuthKey_XXXX.p8`, then `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `APPLE_API_KEY_ID` | That key's id, the `XXXX` in its file name |
| `APPLE_API_ISSUER_ID` | The issuer UUID shown above the keys list |

All six need an Apple Developer Program membership. With the first three, a
release is signed; with all six, it is notarized as well.

### Doing it by hand

`scripts/package-release.sh` signs with whatever certificate is on the Mac
that runs it, and `scripts/notarize-release.sh` notarizes and staples what it
produced:

```bash
scripts/package-release.sh
APPLE_API_KEY_ID=XXXX APPLE_API_ISSUER_ID=UUID APPLE_API_KEY_FILE=~/keys/AuthKey_XXXX.p8 \
  scripts/notarize-release.sh
```

The notarize script refuses before uploading anything if the app **or** the
`macup` binary is not signed with a Developer ID or was signed without the
hardened runtime, because Apple would reject it minutes later with a less
obvious message. It submits the app zip, then the tool in a zip of its own —
that carrier zip is not published — staples the app, and ends by running
`spctl --assess` on the app and on the tool extracted from the tarball, which
is what macOS itself will say about each downloaded copy. The tool's
assessment needs a network connection, because an unstapled executable's
notarization is looked up online; a failure there is reported, not fatal.

**Unverified so far**: no Mac the project has used has a Developer ID
certificate, so the signed and notarized paths have never been run end to
end. The first release built with the secrets in place should be treated as a
rehearsal: run the workflow with `workflow_dispatch` (no tag), which builds,
signs, and notarizes but publishes nothing.

## App distribution

Initial public:
- signed + notarized download from GitHub Releases/project site
- later Homebrew cask if appropriate

## Signing

Never commit certificates or private keys. They live in the repository's
Actions secrets, are decoded into a keychain created for that one job, and go
with the runner; see "Signing and notarizing" above for the list.

## Artifacts

Release should include:
- CLI archive
- app/DMG or zip
- SHA256SUMS
- release notes
- provenance/signature metadata where practical

## Versioning

Semantic Versioning for MacUp releases.

Provider parsers are compatibility-sensitive; parser fixes can be patch releases unless behavior/API changes.

## Changelog

Maintain human-readable changes:
- Added
- Changed
- Fixed
- Security
- Provider compatibility

## Backward compatibility

Before v1:
- config migrations still required when schemas change

After v1:
- do not silently discard user policy during migration
