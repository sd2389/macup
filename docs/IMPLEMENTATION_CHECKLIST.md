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

- `scripts/test.sh`: 272 tests (228 core, 44 CLI), all passing; no test runs
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

- [x] The app has the same feature (CLAUDE.md §26 rule 13): Settings →
      Scheduling with switch, frequency, day, time, and refresh; the exact
      command shown before installing; warnings from `ScheduleStatus`;
      next-check lines on the Dashboard and in the menu bar
- [x] `MacUp.app` bundles the CLI at `Contents/Helpers/macup` and schedules
      that copy, so app and scheduled CLI cannot be different versions
- [x] App view-model tests. The app is now `MacUpAppCore` (a library) plus a
      one-line entry point, because a test target cannot import an executable;
      `AppModel` takes an injected `AppEnvironment` instead of building its own
      runner, file system, authenticator, and camera. `Tests/MacUpAppTests`
      covers the glanceable status, the counts, overlapping checks, failed
      schedule changes, and the schedule and security busy flags staying
      separate — and asserts directly that no test opens a camera, prompts for
      authentication, runs a provider command, installs a launchd agent, or
      touches the real config and state directories.

## Approval before a change (biometrics)

- [x] `BiometricAuthorizing` protocol, `LocalAuthenticator` over
      `LocalAuthentication`, and a fake so no test shows a prompt
- [x] The sensor is read from macOS (`LABiometryType`), never assumed: Touch
      ID, Face ID, and Optic ID all map, and an unknown sensor is reported as
      unnamed rather than guessed at
- [x] MacUp never sees a fingerprint, a face, or a password; it passes a
      reason string it wrote itself and receives a yes or a no
- [x] One `ApprovalGate` for every modifying action, so the execution engine
      cannot skip it later
- [x] Fails closed: an approval MacUp could not obtain is a refusal (exit 77)
- [x] `security.requireApproval` and `security.allowPasswordFallback`
- [x] `macup security status [--json]`, `macup security require on|off`
- [x] Changing the requirement is itself gated by the rule in force
- [x] MacUp refuses to require an approval this Mac could never give, rather
      than leaving the user unable to change anything
- [x] The app has the same feature: Settings → Approval, above the sections it
      governs, with the sensor named and the honest caption
- [x] Documented as a confirmation, not a lock, in the CLI reference, the
      trust document, the README, and the UI itself
- [x] A camera face match of MacUp's own, built at the owner's explicit
      request after the limits were stated. Constrained so it cannot be
      mistaken for security:
  - [x] Named `cameraFace`, never `faceID`, everywhere it is reported
  - [x] Approves early only; a mismatch falls through to macOS, so it can
        never lock anyone out and never replaces the macOS check
  - [x] Off by default, and the validator warns when it is on but approval is
        not required
  - [x] Stores numbers, not images, owner-only in the state directory; the
        camera is open only for the moment of capture
  - [x] Reports the spread of the enrolled samples, and says plainly when the
        spread is wider than the threshold so matching cannot work
  - [x] Every surface — CLI, app, README, trust document — says a photograph
        of the enrolled person passes it
  - [x] Reachable in one click: the app's Features screen, one row per
        feature with one switch each
- [ ] Face matching accuracy is untested against real faces. Vision's feature
      prints were built for image similarity, not identity, so the default
      threshold is a starting point rather than a tuned value.

### Verification (scheduling)

- `scripts/test.sh`: 248 tests, all passing.
- `scripts/check-trust-invariants.sh`: passing, with the two new scheduling
  invariants (no system daemon; the agent runs only `check --save-state`).
- Manual, read-only on the development Mac: `macup schedule`,
  `macup schedule status --json`, `macup schedule enable --help`. No agent
  was installed and `macup schedule enable` was not run.
- The app's Settings pane was rendered in both states (schedule off, and a
  weekly schedule read from a temporary configuration directory) with
  `MacUp --snapshot-dir`. Nothing was installed.

## Phase 2 — policy + planning

Core and both surfaces landed. `docs/CLI.md` is the reference for the exact
commands and flags, and this checklist deliberately does not duplicate a
syntax it does not own.

- [x] `PolicyEngine`: precedence per item, then provider, then global default,
      and never returns `inherit`
- [x] Three overrides on top of precedence, all failing closed: a
      configuration MacUp could not read allows nothing, a disabled provider
      allows nothing, a provider-pinned item allows nothing
- [x] Risk escalation that `confirmMajorUpdates` cannot buy past: macOS
      updates, OS updates, an administrator prompt, a restart, a config or
      lockfile rewrite, a major runtime change, and unknown risk
- [x] The macOS rule checks the provider rather than the OS-update signal,
      because `softwareupdate` reports Safari and security updates without
      marking them as OS updates
- [x] `PolicyIntent`: an unattended run only ever allows `auto`, and an
      escalated `auto` item comes back as a review item rather than running
- [x] Every decision carries a human-readable reason naming the item, so a
      plan listing twenty skips says which item each line is about
- [x] `PolicyEditor` as the single door for a policy change, shared by both
      surfaces: validates the package ID first, refuses a configuration with
      errors, refuses an edit whose result would be invalid, reports the value
      it replaced, and says plainly when there was nothing to change
- [x] A file containing keys MacUp does not know is left exactly as written,
      because an unknown key is already a configuration error and the file is
      therefore refused rather than re-encoded (docs/CONFIGURATION.md)
- [x] `PolicyListing` resolves inheritance through the engine, so a listing
      cannot disagree with the decision the user will get, and reports item
      keys it could not parse instead of dropping them
- [x] `UpdatePlanner`: runs nothing, reuses the installation the check chose,
      and hands providers a runner wrapped in the read-only guard
- [x] `ExecutionPlan` carries item, versions, risk, rationale, exact
      executable and argument array, network/privilege/restart/config-change
      expectations, verification steps, and rollback capability
- [x] Exact command rendering, with a display-safe form kept separate from the
      real argument array
- [x] Every provider plan names a single item, so an exclusion means something
- [x] Provider command shapes confirmed against `brew help upgrade`,
      `mise upgrade --help`, and `npm help install`, not from memory
      (docs/PROVIDER_NOTES.md records what each one changed)
- [x] Refusals rather than guesses: a pinned Homebrew item, an ambiguous
      formula/cask namespace, a mise exact pin, a project or system mise
      config, a mise request MacUp cannot attribute, an npm version position
      that is not plainly a version, and any item whose name MacUp cannot
      display exactly
- [x] macOS refuses to plan and says why, and declares no `planUpdates`
      capability, so the planner refuses it by capability as well
- [x] No plan claims rollback
- [x] Exit criteria: a dry run executes nothing; an ignored or pinned item
      cannot enter an executable plan; policy precedence fully tested

## Phase 3 — safe execution

- [x] `ModifyingCommandRules`: the four shapes MacUp may ever run, in one
      reviewable place. Positional arguments are checked rather than trusted
      (no leading `-`, no control or bidirectional-override characters), and
      the count is **exact**, because naming too few is the dangerous case
- [x] `ExecutionGuard`: wraps the runner for the length of one plan and
      refuses anything that is not one of that plan's own steps or
      verification commands, matched by executable, argument array, and
      effect — and a change must match a reviewed rule as well
- [x] Verification is given no modifying rules at all, and only the read-only
      rules, so it cannot reach the metadata refresh either
- [x] `ExecutionEngine` re-reads the configuration file and re-asks the policy
      engine immediately before each item (CLAUDE.md §2.20)
- [x] A `confirm` decision runs only for a confirmed item, and only when
      somebody was there to confirm it
- [x] An unattended run refuses a plan that may need a password or a restart
- [x] Items run strictly one at a time; never overlapped
- [x] A failed step ends that item, and a failure ends the run's appetite for
      high-risk and unknown-risk changes
- [x] Refuses a plan it cannot carry out faithfully: no steps, or a step
      without a usable time limit
- [x] The environment comes from the owning provider
      (`executionEnvironment(context:)`), because
      `HOMEBREW_NO_INSTALL_CLEANUP` and
      `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK` have no flag; detection runs
      once per provider per run through a read-only runner, and a provider
      MacUp cannot find means the plan does not run
- [x] Steps run with the home directory as the working directory, so a
      project-local configuration cannot change what a command means
- [x] Homebrew selected-item update (formula and cask, `--yes`, explicit
      `--formula`/`--cask`) and verification from `brew info`
- [x] npm selected-package update at a named version, and verification from
      `npm ls -g`
- [x] mise safe-range update (`--cd`, never `--bump`) and verification from
      `mise ls`, comparing the active version
- [x] Verification reported honestly: `targetNotReached` for a version that
      did not move, `failed` for output MacUp could not parse, never rounded
      up to success
- [x] `HistoryStore`: one redacted JSON object per line, owner-only, never
      through a symlink, trimmed by atomic replace, undecodable lines counted
      and reported rather than guessed at
- [x] Every attempt and every skip recorded with its reason; a dry run records
      nothing, because it attempted nothing
- [x] History that cannot be written is logged and does not abort the run
- [x] Cancellation reaches the running command and stops the loop
- [x] `scripts/check-trust-invariants.sh` updated: modifying verbs are
      permitted only in the one rules file and the one planning file per
      provider, and still fail for the CLI, the app, discovery, and
      scheduling. `--bump` may appear nowhere
- [x] Exit criteria: no blanket provider upgrade; policy rechecked immediately
      before execution; failures do not silently continue through high-risk
      changes

## Phase 4 — Doctor

- [x] Eleven deterministic checks, each its own small type with a stable
      identifier, driven only by a `DiagnosticInput`, so a check cannot reach
      for a fact nobody gathered
- [x] Provider availability and provider results
- [x] Multiple Homebrew installations, and a non-standard prefix
- [x] Executable architecture, read from the Mach-O header rather than through
      `lipo` or `file`, and only the header
- [x] Login-shell `PATH` against MacUp's own
- [x] Runtime ownership: mise reporting one version active while an earlier
      `PATH` entry runs another
- [x] npm ownership: which Node owns the global packages, and where they
      actually live
- [x] Configuration diagnostics, and item policies that no longer name
      installed software
- [x] MacUp's own directories: usable, private, owned by you
- [x] Whether a configured schedule is really installed and loaded
- [x] Stable, namespaced finding identifiers, ordered deterministically —
      severity first, then identifier, then title, then detail — so two runs
      over one machine agree
- [x] Findings de-duplicated, and a check stands down when a provider already
      reported the same thing
- [x] Severity as a judgment: a provider that is not installed is
      information; a directory another user can write is an error
- [x] A fact MacUp does not have becomes a finding that says so: undetermined
      architecture produces nothing, an unreadable launchd state is unknown, an
      uninspectable directory is unknown, unparsed output is unparsed
- [x] Reading the login shell is the one command Doctor issues; it goes
      through `CommandRunning` as a read-only request, the captured
      environment is compared and dropped, and the reader is injectable so
      tests describe a shell instead of starting one
- [x] Everything that reaches a finding is redacted and sanitized: the home
      directory becomes `~`, and no finding prints an environment variable's
      value
- [x] Doctor explains. It never fixes, and never offers to

### Verification (Phases 2–4)

- `scripts/test.sh`: 599 tests (516 core, 44 CLI, 39 app), all passing. No
  test runs a modifying provider command in any form.
- `scripts/check-trust-invariants.sh`: passing.
- No modifying provider command was run on the owner's machine during this
  work (CLAUDE.md §26 rules 9 and 11). The execution engine's behaviour is
  proven against a scripted provider and a fake runner.
- Manual verification for the surfaces belongs with the surface work; see
  `docs/CLI.md`.

### Open limitations

- [ ] Face matching accuracy is untested against real faces. Vision's feature
      prints were built for image similarity, not identity, so the default
      threshold is a starting point rather than a tuned value.
- [ ] Process-group termination for modifying commands. Cancellation reaches
      the child; a child that spawns grandchildren is not yet cleaned up as a
      group.
- [ ] The camera face match cannot capture in a locally built app, because the
      bundle is ad-hoc signed and macOS will not grant camera access to a
      bundle with no team identifier. Both surfaces say so
      (docs/DEVELOPMENT.md).

### Carried into later phases

- Scheduled *updating* (explicit-`auto` items only), notifications, and
  battery/metered-network awareness — Phase 6. Notifications need the app
  bundle: `UNUserNotificationCenter` does not work from a bare CLI.
- Rollback. No provider action has a tested strategy, so every plan reports
  rollback as unavailable, and will keep doing so until one does
  (CLAUDE.md §2.22).
- macOS update installation. Out of scope until it has its own security
  review and tests; see `docs/PROVIDER_NOTES.md` for why.

## Phase 5a — read-only desktop app (pulled forward at the owner's request)

Built on the Phase 1 engine before Phases 2-4. The update, policy, Doctor and
History controls those phases needed have since landed on top of it, and are
listed under "Surfaces" below.

- [x] Login-shell environment discovery so a Finder-launched app finds the
      same tools as the terminal (prompt hooks included)
- [x] `MacUpAppCore` library at `Apps/MacUpApp/MacUpApp` plus a one-line
      executable entry point at `Apps/MacUpApp/Main`, MacUpCore only, no new
      dependencies
- [x] `AppModel` takes an injected `AppEnvironment` instead of building its
      own runner, file system, authenticator, and camera, so it can be tested
      without running anything real
- [x] Dashboard, Updates (with inspector), Doctor, History, Features
- [x] Settings window and MenuBarExtra (no update-everything)
- [x] Status in words plus symbols, never color alone; light and dark checked
- [x] Loading, empty, and error states
- [x] `scripts/build-app.sh` and a DEBUG snapshot mode for UI review; the
      bundle also carries the `macup` CLI at `Contents/Helpers/macup`
- [x] `Tests/MacUpAppTests` — the app's model, plus a suite asserting that no
      test touches the host

### Surfaces for Phases 2 to 4

Every feature ships in both the `macup` CLI and the app, in the same piece of
work (CLAUDE.md §26.13).

- [x] CLI: `plan`, `update` (with `--dry-run`, `--yes`, `--stop-on-failure`),
      `policy list|set|clear`, `exclude`, `provider enable|disable`,
      `doctor`, `history`, each with `--json` where it makes sense, plus exit
      codes 4 (an update failed) and 5 (Doctor found something)
- [x] App: Updates with per-item policy controls and the exact command, the
      execution review sheet, applying with per-item progress and a working
      Stop, Doctor, History, and the Settings policy section
- [x] Both surfaces put policy edits behind the approval gate when
      `security.requireApproval` is on, because deciding what MacUp may
      update is the decision every later one rests on
- [x] Both take every decision from `MacUpCore`; neither builds a command,
      resolves a policy, or judges risk of its own

- [ ] Xcode project wrapping the same sources (waiting on Xcode)
- [ ] SwiftUI previews (the preview macros ship with Xcode)
- [ ] Asset catalog (needs Xcode). The icon itself is drawn from source by
      `scripts/make-icon.swift` rather than committed as a binary.

## Phase 8 — what the owner asked for after v0.4.0

Six pieces of work, in the order they are being built. Each ships in both
surfaces, with tests and docs, in its own commit (CLAUDE.md §26.13).

### 8.1 — Every package manager on this Mac (read-only) — done

- [x] A catalog of the package managers and version managers MacUp can
      recognise, each with its executable, standard locations, and whether a
      MacUp provider manages it (`KnownTools.swift`, 26 entries)
- [x] A scanner that resolves each through `ExecutableResolver` (so an
      untrusted location is reported, never run) and reads its version with
      one fixed read-only argument array, behind `CommandAllowlist.toolScan`
- [x] Tools detected by a file alone, such as nvm and SDKMAN!, where there is
      no executable to resolve
- [x] CLI: `macup provider scan`, with `--all` and `--json`
- [x] App: "Also on This Mac" on the Providers screen, with Scan Again
- [x] Tests: fake file system and runner, every shape (absent, found,
      several installations, untrusted location, version command fails, a
      catalog entry whose command the guard refuses)

### 8.2 — Self-update through whatever installed MacUp — done

- [x] MacUp knows how it was installed (Homebrew cask, Homebrew formula, or
      a copy you downloaded): a formula from the running command being inside
      Homebrew's own Cellar, a cask from Homebrew reporting that cask plus the
      running app being where a cask puts one. A folder in the Caskroom is not
      evidence, and when Homebrew cannot be asked MacUp says it does not know
- [x] An update plan for the first two, built from the Homebrew data MacUp
      already reads — no new network code, and the one shared `UpdateRun`
      path, so updating MacUp cannot skip a confirmation the ordinary path
      makes
- [x] A downloaded copy is told where its releases are, and nothing more
- [x] Homebrew that could not be used reads as "unknown", never "up to date"
- [x] CLI: `macup self-update`, with `--dry-run`, `--refresh`, `--json`
- [x] App: Settings > MacUp Updates, with Update MacUp… (the ordinary review
      sheet) or Open Releases Page
- [x] Tests: each installation shape, policy that forbids it, only MacUp's
      own item is ever in the plan, and that a downloaded copy plans nothing

### 8.3 — Leftovers of apps that are already gone — done

- [x] A scan of `~/Library` for files whose app is no longer installed,
      grouped by the bundle identifier they are named after, biggest first
- [x] Matched by bundle identifier only, never by resemblance, and only with
      evidence that an app rather than a tool wrote them; nothing is ticked
- [x] A name no scan found cannot be uninstalled by typing it
- [x] CLI: `macup uninstall --orphans`, with `--json`, and
      `macup uninstall leftovers:<bundle-id>` for the ordinary review
- [x] App: "Left Behind by Apps You Removed" on the Uninstall screen
- [x] Tests: an orphan found, an installed app's files never offered, a
      longer identifier left to its own app, Apple's namespace left alone,
      evidence required, suffixes stripped, and the plan ticking nothing

### 8.4 — Scheduled updating (ADR-023, owner decision 2026-10-07) — done

- [x] ADR-023 recording that the launchd job may now also run
      `macup update --scheduled`, and what guards that
- [x] `scripts/check-trust-invariants.sh` allows exactly those two command
      shapes, and fails if any other argument can be added to the agent
- [x] A scheduled update touches only items that resolve to `auto`, and
      refuses anything that may need a password or a restart (the engine's
      unattended rules, which already existed)
- [x] Approval that needs the device owner stops a scheduled run outright
- [x] A scheduled run records what it left alone in History, since nobody is
      watching the screen it would otherwise be said on
- [x] Notifications from the app bundle: what was updated, what failed, and
      what is waiting, once per run
- [x] CLI: `macup schedule enable --install-updates`, `macup update --scheduled`
- [x] App: Features > Check automatically, with the switch, the warning when
      approval is on, and the exact command launchd runs
- [x] Tests: an `ask` item is never updated, approval refuses the run, the
      history says a scheduled run did it, the agent's command is fixed, the
      setting is off unless the file says otherwise, and the app notifies
      once per run

### 8.5 — Doctor that can fix what it is sure about — done

- [x] A finding may carry one fix, from a closed list of four actions, each
      changing only MacUp's own configuration or its own launchd agent
      (ADR-024)
- [x] A fix is always user-initiated, always shows what it will change
      first, asks, and goes through the approval gate
- [x] Findings with no safe fix keep saying what to do by hand
- [x] CLI: `macup doctor --fix <finding-id>`, with `--dry-run` and `--yes`
- [x] App: a button on the findings that have one, with a review sheet
- [x] Tests: every fixable finding, a refused fix, a dry run, a fix whose
      precondition changed since the finding was made, and a configuration
      MacUp cannot read
- [ ] Not done, and recorded in ADR-024: Doctor fixes are not in the update
      History, which is about packages. The result is printed or shown, and
      `macup config show` and `macup schedule status` report the state

### 8.6 — Developer ID signing and notarization — done, unverified

- [x] `scripts/build-app.sh` signs with a Developer ID when one is present,
      and adds the hardened runtime and a secure timestamp in that case only,
      because that is what Apple will notarize
- [x] `scripts/notarize-release.sh`: a separate step that checks the
      signature before uploading, submits, staples, repacks, rewrites
      `SHA256SUMS`, and ends with `spctl --assess`
- [x] `.github/workflows/release.yml` reads the certificate and the App Store
      Connect key from repository secrets, into a keychain made for that one
      job, and publishes a pre-release that says so when they are absent
- [x] `docs/RELEASE.md` lists exactly which six secrets to add, and how to do
      the same by hand
- [ ] **Unverified**: no Mac the project has used has a Developer ID
      certificate (`security find-identity -v -p codesigning` finds none), so
      the signed and notarized paths have never run end to end. The first run
      with the secrets in place should be a `workflow_dispatch` rehearsal,
      which builds, signs, and notarizes but publishes nothing


### 8.4 — What needs an administrator, written down rather than refused — done

The owner asked on 2026-10-08 for an uninstall to be finishable when an
installer put its files in place as root, with the authority asked for rather
than assumed (ADR-025). MacUp still never escalates.

- [x] `AdminRemovalScript` turns the administrator-only part of a reviewed
      plan into a `0600`, non-executable script in MacUp's state directory:
      `set -euo pipefail`, a root check, one line per item in the plan's
      order, and a header saying how many items and that the removals are
      permanent
- [x] Only `rm`, `launchctl`, and `pkgutil` may appear in it; anything else is
      left out with its reason, whatever built it
- [x] Arguments single-quoted, path operands behind `--`, receipt identifiers
      checked character by character, and a path holding a control character,
      a newline, or a bidirectional override left out rather than written
- [x] `macup uninstall <target> --admin-script [--json]` writes it, prints
      what it covers and the command, and removes nothing
- [x] The app's review sheet offers **Write Administrator Script…**, then
      Review Script, Copy Command, Show in Finder, and Open Terminal — it can
      copy and open, never run
- [x] The root-owned app bundle itself is on the list, so the script finishes
      the job rather than only the leftovers
- [x] The maker's own uninstaller is found, named, and its signer reported
      only after `SecStaticCodeCheckValidity` passes; the folder holding it is
      kept out of the script
- [x] `scripts/check-trust-invariants.sh` fails the build if
      `AdminRemovalScript.swift` names a runner, `chmod`, or `NSWorkspace`, or
      if any other file under `Sources/` or `Apps/` names the script
- [x] Tests: ordering, quoting, dash guards, refusals, the three-tool rule,
      file mode, the CLI's text and JSON, and the app's view model
