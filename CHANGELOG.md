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
