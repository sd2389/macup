# Changelog

All notable changes to MacUp are recorded here, grouped as described in
`docs/RELEASE.md` (Added, Changed, Fixed, Security, Provider compatibility).
MacUp follows Semantic Versioning once releases begin.

## [Unreleased]

### Added
- Scheduled read-only checks: `macup schedule enable`, `macup schedule
  disable`, and `macup schedule status [--json]`. Enabling installs a launchd
  **user agent** (`com.macup.check`) that runs `macup check --save-state` at
  the chosen time. It runs as you, needs no administrator authorization,
  leaves no process running between checks, and `disable` removes it
  completely. There is no scheduled updating: this version still cannot
  modify a package.
- `macup check --save-state` writes the report to
  `~/.local/state/macup/last-check.json`, which `macup schedule status`
  summarises.
- `schedule.refresh` (default `true`) controls whether a scheduled check
  refreshes package metadata first. Without it `brew outdated` reads local
  metadata that may be weeks old, so a nightly check would report almost
  nothing; a refresh updates package lists only.
- `MACUP_LAUNCH_AGENTS_DIR` overrides the LaunchAgents directory, for testing.
- Homebrew tap: `brew install sd2389/macup/macup` builds MacUp from the
  tagged source.

### Fixed
- `macup config show` no longer presents the `schedule` section as if it
  worked while nothing read it. Before scheduling existed, turning it on in
  the file was accepted, validated, and echoed back, and then nothing ran.
- CI and the development guide find the built `macup` through SwiftPM
  (`swift build --show-bin-path`, `swift run`) instead of assuming
  `.build/debug`, which newer toolchains no longer use.

## [0.1.0] - 2026-09-26

Read-only alpha: MacUp reports what is outdated and never changes anything.

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
- Read-only SwiftUI desktop app: Dashboard, Updates, Doctor, History,
  Settings window, and a menu bar extra, built with `scripts/build-app.sh`.
- Login-shell environment discovery so the app finds the same tools as the
  terminal.
- `make install` / `make uninstall` for the CLI; `macup providers` and
  `macup config` shortcuts; examples in `macup --help`; risk levels colored
  on terminals.

### Security
- Security policy with private vulnerability reporting, and the Contributor
  Covenant 2.1 as the Code of Conduct.
- Dependabot updates for GitHub Actions and Swift packages.
- Provider output is treated as untrusted: names with control characters,
  bidirectional overrides, or leading dashes are skipped; human output is
  sanitized for the terminal, and JSON output escapes the same characters;
  errors are redacted.
- Hardening from a pre-release security audit:
  - A configuration file (or its directory, or a symlinked file's target
    directory) that other users could change is ignored entirely, so it cannot
    choose which executables MacUp runs. The ownership checks and the read now
    use one open file.
  - A configured `executablePath` is checked exactly as written; empty or
    padded values fail instead of falling back to `PATH`.
  - Standard install locations (`/opt/homebrew/bin`, `/usr/local/bin`) are used
    only when root or the user controls the file and every directory above it.
  - Redaction covers more credential shapes (multi-word and unterminated
    values, `KEY`/`PASS`/`DSN` names, JSON keys, token-only URL userinfo,
    Stripe and Google keys).
  - Checks that failed, were cancelled, skipped unreadable updates, or got
    incomplete results from mise are reported as incomplete (exit status 2 in
    the CLI; a warning instead of a checkmark in the app), never as "up to date".
  - Truncated provider output is an error; npmrc files can no longer forward
    `NODE_OPTIONS`, `DYLD_*`, or similar variables; the fresh `softwareupdate`
    scan is guarded as a metadata refresh; MacUp refuses to run as root.
  - Builds use the dependency revisions pinned in `Package.resolved`
    (`--force-resolved-versions`), and CI fails if they change.
  - `make app` builds a release app; the debug-only snapshot mode writes only
    into a private directory.

### Provider compatibility
- Verified against Homebrew 7.0.6, npm 10.9.8/11.17.0, mise 2026.7.3, and
  `softwareupdate` on macOS 27.0; parsers accept older output shapes.

[Unreleased]: https://github.com/sd2389/macup/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/sd2389/macup/releases/tag/v0.1.0
