# Implementation Checklist

Working checklist required by `CLAUDE.md` §26 (rule 13). Update it before and
after each phase. Items are checked only when implemented **and** covered by
tests or an explicit manual verification step.

## Ground rules for every phase

- No real upgrades, installs, cleanups, prunes, or uninstalls on the owner's
  machine. Read-only detection commands only.
- Tests never execute real provider binaries; they use fixtures, a fake
  command runner, or disposable stub executables.
- Every external process goes through `CommandRunner` with an executable path
  and an argument array.

## Phase 0 — repository foundation

- [x] Materialize the build-kit files bundled in `MACUP_MASTER_BUILD_SPEC.md`
      (CLAUDE.md, docs/, SECURITY.md, CONTRIBUTING.md, templates, example config)
- [x] LICENSE (Apache-2.0), CHANGELOG.md, .gitignore
- [x] `Package.swift` with `MacUpCore` library, `macup` executable, test targets
- [x] Swift Testing test targets that run under full Xcode and under Command
      Line Tools (`scripts/test.sh` supplies the macro plugin path on CLT)
- [x] `CommandRunning` protocol + `ProcessCommandRunner`
  - [x] executable path + argument array, never a shell
  - [x] environment allowlist + overrides
  - [x] working directory
  - [x] timeout with terminate → kill escalation
  - [x] task cancellation
  - [x] stdout/stderr capture with size limits
  - [x] optional streaming output callback
  - [x] exit status + termination reason + start/end timestamps
  - [x] display-safe command rendering separate from the real argument array
  - [x] secret redaction for anything logged or displayed
- [x] Intentional executable resolution (configured → shell PATH → standard
      locations), relative PATH entries ignored
- [x] Config paths (`~/.config/macup/config.json`, `~/.local/state/macup/`)
- [x] `macup --help` / `macup --version`
- [x] GitHub Actions CI: build, tests, CLI smoke, no-shell static check
      (workflow written and its steps verified locally; first hosted run happens on push)
- [x] Exit criteria: builds cleanly, tests run, `macup --help`, no provider
      modifications

## Phase 1 — read-only engine

- [x] Domain models: ProviderID, PackageID, ManagedItem, InstalledVersion,
      AvailableVersion, UpdateCandidate, UpdateRisk, UpdatePolicy,
      ExecutionPlan, ExecutionStep, ExecutionResult, VerificationResult,
      ProviderCapability, ProviderStatus, DiagnosticFinding, HistoryEntry
- [x] Typed error categories (`MacUpError.Kind`)
- [x] Version comparison that never assumes SemVer; opaque fallback
- [x] Risk assessment from version change + provider signals; unknown stays unknown
- [x] Versioned configuration: load, validate, fail closed, atomic write,
      backup-before-migration, migration framework, permission checks
- [x] Read-only command guard: `check` can only run allowlisted read-only
      invocations (plus explicit metadata refresh with `--refresh`)
- [x] Homebrew: detection (exact path, version, prefix, multiple installs),
      `brew outdated --json=v2`, `brew info --json=v2 --installed`,
      `HOMEBREW_NO_AUTO_UPDATE=1` on every read-only call, pins reflected
- [x] npm global: exact npm/node/prefix/root, ownership hints, `npm ls -g`,
      `npm outdated -g` (non-zero exit + valid JSON), scoped names, npm itself,
      installed-newer-than-latest
- [x] mise: exact binary/version, `mise ls --json`, `mise outdated --json`
      (no `--bump`), requested range preserved, global vs project scope,
      lockfile presence, inactive versions
- [x] macOS: `softwareupdate --list --no-scan` (scan only with `--refresh`),
      restart detection, ambiguity → finding, never install
- [x] Concurrent check engine (bounded structured concurrency)
- [x] CLI: `macup` (default = check), `macup check [--refresh] [--json]`,
      `macup provider list`, `macup config path`, `macup config show`
- [x] Versioned JSON output schema, no ANSI when not a TTY, terminal-safe output
- [x] Ctrl+C cancellation handled cleanly
- [x] Fixture tests for every parser; hostile-name tests; provider absence and
      failure tests; integration test with stub executables
- [x] Exit criteria: `macup check` modifies no packages; fixtures cover parsers;
      absent providers handled cleanly

### Verification (Phase 1)

- `scripts/test.sh`: 194 tests (171 core, 23 CLI), all passing; no test runs
  a real provider binary.
- `scripts/check-trust-invariants.sh`: passing.
- Manual, read-only on the development Mac: `macup check`, `--verbose`,
  `--json`, `macup provider list`, `macup config show`. Every command run was
  on the allowlist with effect `readOnly`; `--refresh` was not run.

### Carried into later phases

- Policy precedence and evaluation (stored and validated now) — Phase 2.
- Execution plans, per-item updates, verification, history — Phases 2–3.
- Process-group termination for modifying commands — Phase 3.
- Cross-provider diagnostics (for example mise-managed Node on PATH while
  npm runs a different Node) and binary-architecture checks — Phase 4 Doctor.
- Login-shell PATH discovery for the app — Phase 5.
