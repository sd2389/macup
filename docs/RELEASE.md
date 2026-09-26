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

## App distribution

Initial public:
- signed + notarized download from GitHub Releases/project site
- later Homebrew cask if appropriate

## Signing

Never commit certificates/private keys.

Use CI secrets and documented Apple notarization workflow.

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
