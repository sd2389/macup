# Release and Distribution

## Development channels

- nightly/internal builds
- alpha
- beta
- stable

## CLI distribution

Initial:
- GitHub Releases

Then:
- Homebrew tap/formula

Desired user experience:
```bash
brew install <tap>/macup
macup check
```

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
