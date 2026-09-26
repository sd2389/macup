# Changelog

All notable changes to MacUp are recorded here, grouped as described in
`docs/RELEASE.md` (Added, Changed, Fixed, Security, Provider compatibility).
MacUp follows Semantic Versioning once releases begin.

## [Unreleased]

### Added
- Project documentation materialized from `MACUP_MASTER_BUILD_SPEC.md`.
- Apache-2.0 license.
- Swift package with the `MacUpCore` library, the `macup` CLI, and Swift
  Testing test targets.
- `ProcessCommandRunner`: argument arrays only, allowlisted environment,
  `/dev/null` stdin, bounded stdout/stderr capture, streaming, timeouts with
  SIGTERM→SIGKILL escalation, and task cancellation.
- Intentional executable resolution (configured path → search path → standard
  locations) that ignores relative `PATH` entries and never falls back from an
  invalid configured path.
- `ReadOnlyCommandGuard` and command recording for read-only operations.
- Secret redaction and terminal-safe rendering of untrusted text.
- `macup config path` and canonical config/state locations.
- CI workflow and `scripts/check-trust-invariants.sh`.
- Domain models, SemVer-agnostic version comparison, and a coarse risk model.
- Versioned configuration (schema 1) with strict, fail-closed validation,
  atomic owner-only writes, and backup-before-migration.
- Read-only providers: Homebrew formulae and casks, npm global packages,
  mise runtimes and tools, and macOS software update detection.
- Concurrent `macup check` (default command) with `--json`, `--refresh`,
  `--provider`, `--inventory`, and `--verbose`; `macup provider list`;
  `macup config show`.
- Read-only command allowlist enforced for every check.

### Security
- Provider output is treated as untrusted: names with control characters,
  bidirectional overrides, or leading dashes are skipped; everything printed
  is sanitized for the terminal; errors are redacted.

### Provider compatibility
- Verified against Homebrew 7.0.6, npm 10.9.8/11.17.0, mise 2026.7.3, and
  `softwareupdate` on macOS 27.0; parsers accept older output shapes.
