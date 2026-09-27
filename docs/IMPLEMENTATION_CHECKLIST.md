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

- `scripts/test.sh`: 248 tests (211 core, 37 CLI), all passing; no test runs
  a real provider binary.
- `scripts/check-trust-invariants.sh`: passing.
- Manual, read-only on the development Mac: `macup check`, `--verbose`,
  `--json`, `macup provider list`, `macup config show`. Every command run was
  on the allowlist with effect `readOnly`; `--refresh` was not run.

## Scheduled read-only checks (pulled forward from Phase 6)

A scheduled *check* depends on neither the policy engine nor the execution
engine, so it did not have to wait for Phases 2 and 3. Scheduled *updating*
still does: it is Phase 6, unchanged.

- [x] `LaunchAgent`: the property list is derived in one place, from the
      configuration, with the exact executable and argument array
- [x] The agent runs `macup check --save-state` and nothing else; a static
      invariant in `scripts/check-trust-invariants.sh` enforces it
- [x] Per-user LaunchAgent in `~/Library/LaunchAgents`, loaded into
      `gui/<uid>`; no daemon, no root, no privilege helper, no authorization
      prompt, no process between runs
- [x] `RunAtLoad` false, so enabling a schedule does not also check at login
- [x] `Scheduler`: install, remove, and status through `CommandRunning` with
      `/bin/launchctl` by absolute path; label and agent path are MacUp's own
      constants, never user text
- [x] `macup schedule enable|disable|status [--json]`
- [x] `macup check --save-state` writes the report atomically, owner-only,
      to `~/.local/state/macup/last-check.json`
- [x] `schedule.refresh` (default on), because an unrefreshed nightly check
      reads weeks-old Homebrew metadata and reports almost nothing
- [x] Weekly defaults to Sunday, stated in the help and shown in status
      rather than left implicit
- [x] Fails closed: `schedule enable` refuses to write a configuration it
      could not read, and refuses to schedule a binary it cannot name
      absolutely or that is not an executable file
- [x] Status reports rather than repairs: installed-but-not-loaded, agent
      that no longer matches the configuration, missing scheduled binary,
      unreadable saved report
- [x] Tests: property list contents, calendar intervals, weekday mapping,
      refused times, install/remove/status through a fake `launchctl`, and
      the CLI end to end. No test installs an agent on the host.

### Verification (scheduling)

- `scripts/test.sh`: 248 tests, all passing.
- `scripts/check-trust-invariants.sh`: passing, with the two new scheduling
  invariants (no system daemon; the agent runs only `check --save-state`).
- Manual, read-only on the development Mac: `macup schedule`,
  `macup schedule status --json`, `macup schedule enable --help`. No agent
  was installed and `macup schedule enable` was not run.

### Carried into later phases

- Policy precedence and evaluation (stored and validated now) — Phase 2.
- Execution plans, per-item updates, verification, history — Phases 2–3.
- Process-group termination for modifying commands — Phase 3.
- Cross-provider diagnostics (for example mise-managed Node on PATH while
  npm runs a different Node) and binary-architecture checks — Phase 4 Doctor.
- Login-shell PATH discovery for the app — Phase 5.
- Scheduled *updating* (explicit-`auto` items only), notifications, and
  battery/metered-network awareness — Phase 6. Notifications need the app
  bundle: `UNUserNotificationCenter` does not work from a bare CLI.

## Phase 5a — read-only desktop app (pulled forward at the owner's request)

Built on the Phase 1 engine before Phases 2–4; update and policy controls
come later.

- [x] Login-shell environment discovery so a Finder-launched app finds the
      same tools as the terminal (prompt hooks included)
- [x] App target in `Apps/MacUpApp/MacUpApp`, MacUpCore only, no new dependencies
- [x] Dashboard, Updates (with inspector), Doctor, History (empty state)
- [x] Settings window (read-only) and MenuBarExtra (no update-everything)
- [x] Status in words plus symbols, never color alone; light and dark checked
- [x] Loading, empty, and error states
- [x] `scripts/build-app.sh` and a DEBUG snapshot mode for UI review
- [ ] Xcode project wrapping the same sources (waiting on Xcode)
- [ ] App icon and asset catalog (needs Xcode)
- [ ] SwiftUI previews (the preview macros ship with Xcode)
- [ ] View-model tests once the app gains its own logic (Phase 2 actions)
