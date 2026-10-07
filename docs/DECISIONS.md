# Initial Architectural Decisions

## ADR-001 — Swift-native
Use Swift for Core, CLI, and native app to keep the product lightweight and deeply macOS-integrated.

## ADR-002 — MacUp is an orchestrator
MacUp does not replace Homebrew/npm/mise. It invokes provider-native tooling and adds discovery, policy, planning, verification, history, and UX.

## ADR-003 — Read-only default
The default command is non-modifying.

## ADR-004 — Central policy engine
Providers cannot bypass user policies.

## ADR-005 — No shell interpolation
External commands use executable + argument arrays.

## ADR-006 — Local first
No backend/account required for v1.

## ADR-007 — launchd
Scheduling uses macOS-native launchd, not cron as the product foundation.

## ADR-008 — No blanket upgrades
Where per-item policies/exclusions exist, execute selected items individually rather than calling an ecosystem-wide update-all command.

## ADR-009 — No universal rollback claim
Rollback is provider/action-specific.

## ADR-010 — Open source first
Core product is developed publicly; monetization can be decided after adoption.

---

# Decisions made during implementation

These record where the implementation interprets or extends the
specification. Review them with each phase.

## ADR-011 — Provider listings carry findings
`inventory` and `outdated` return their results together with diagnostic
findings (`ProviderListing`) instead of bare arrays, so parse ambiguities
("skipped an entry MacUp could not read") are reported rather than dropped.
Otherwise the provider protocol follows CLAUDE.md §7; `makePlan` and
`verify` fail closed with `unsupported` until Phases 2–3.

## ADR-012 — Central read-only allowlist
Read-only operations run every command through `ReadOnlyCommandGuard` and
one reviewable allowlist (`CommandAllowlist`). Read-only is a structural
guarantee, not a convention; adding a command is a visible trust decision.

## ADR-013 — The CLI's search path is the user's shell PATH
For the CLI, step 2 of binary resolution ("login-shell discovery") is the
`PATH` the CLI inherited from the user's shell, before standard locations.
The app will need explicit login-shell discovery (Phase 5). An invalid
configured executable path fails closed instead of falling back.

## ADR-014 — Strict configuration
Unknown keys, providers, and package IDs are errors that disable automatic
modification, because a typo must never silently turn a block into an
allowance. `XDG_*` variables do not relocate MacUp's files, so the CLI and
the app always share one configuration.

## ADR-015 — mise checks run from the home directory
Global maintenance must not depend on the shell's current directory, and
project-local configuration is informational in v0.1. Running mise from
the home directory makes checks deterministic and matches that scope.

## ADR-016 — macOS updates are identified by their `softwareupdate` label
`macos:<label>` (for example `macos:macOS 27.2 Beta-26B5091g`) is the
identity `softwareupdate` itself uses, and it distinguishes non-OS updates
(Safari, Command Line Tools) that have no OS version.

## ADR-017 — Swift Testing, with a Command Line Tools workaround
Tests use Swift Testing. With only the Command Line Tools installed, SwiftPM
does not locate the testing macro plugin, so `scripts/test.sh` passes its
path; Xcode and CI need nothing extra.

## ADR-018 — A read-only desktop app before Phases 2–4
At the owner's request, the SwiftUI app was built on the Phase 1 engine
ahead of the spec's phase order. It only reports; update and policy
controls land with Phases 2–3, and the app gains them without changing its
structure because all behavior stays in MacUpCore.

## ADR-019 — App sources in Apps/MacUpApp, built by SwiftPM until Xcode
The app lives in the spec's `Apps/MacUpApp/MacUpApp` layout and is a
SwiftPM executable target, so it builds and runs with only the Command Line
Tools (and compiles in CI). When Xcode is installed, an Xcode project wraps
the same folder for icons, previews, signing, and notarization.

## ADR-020 — Login-shell environment discovery is the one sanctioned shell `-c`
The app runs the user's login shell (from the account database, listed in
`/etc/shells`) interactively with a fixed script and captures `env -0`.
Only a MacUp-generated nonce is inserted into the script; output is parsed,
never executed, never logged. `scripts/check-trust-invariants.sh` allows it
in that one file.

## ADR-021 — Settings is a standard macOS Settings window
The spec lists Settings in primary navigation; macOS convention (and the
spec's "standard macOS conventions first") puts it in the Settings window
(⌘,), reachable from the app menu and the menu bar. The sidebar holds
Dashboard, Updates, Doctor, and History.

## ADR-022 — A reviewed uninstaller, by the owner's decision
The spec put uninstall and cleanup out of scope for v0.1. On 2026-09-29 the
owner asked for an uninstaller that removes an app ("like ChatGPT, Claude or
a game"), a package ("anything like python or npm"), or MacUp itself, with no
residue. It ships with the trust rules intact:

- Nothing is removed without a plan the person reviewed and confirmed, in
  either surface. The plan names the package manager's exact commands
  (`brew uninstall --formula --force`, `brew uninstall --cask`, `brew
  services stop`, `npm uninstall -g`, `mise uninstall`) and every file with
  its size. Never `--zap`, `--ignore-dependencies`, `autoremove`, `cleanup`,
  or a configuration rewrite.
- How files go is chosen for each uninstall, Move to Trash or Delete
  Permanently, and starts at the Trash; there is no remembered answer. A
  permanent deletion asks once more, saying it cannot be undone.
- What clearly belongs to the item is ticked; data (app data, formula data
  such as `var/mysql`) and anything matched only by name are not.
- Only paths in the confirmed plan are removed, each checked again just
  before removal (a symbolic link is removed as a link, never followed, and
  nothing outside the allowed folders is touched). What needs an
  administrator is listed with manual steps; MacUp never uses one.
- An app that is open, a formula other formulae need, and a configuration
  MacUp cannot read all stop an uninstall. Interactive only: nothing
  scheduled or unattended can uninstall.
- Every uninstall is recorded in History.


## ADR-023 — A schedule may install Auto Update items, by the owner's decision
Until now the launchd agent could run exactly one command,
`macup check --save-state`, and `scripts/check-trust-invariants.sh` enforced
that literally. On 2026-10-07 the owner asked for scheduled updating. The
invariant is loosened to exactly two command shapes and no others:

- `macup check --save-state` — unchanged, and still what a schedule runs
  unless installing is turned on;
- `macup update --scheduled` — installs only what was decided in advance.

What keeps the trust contract intact:

- **Only Auto Update items.** The plan is built with the unattended intent,
  so an item that resolves to Ask First is skipped with its reason rather
  than confirmed by the schedule; ignored and pinned items are never touched,
  and a provider that is off is never run. Policy is re-read immediately
  before each item, as in any run.
- **Nothing that needs a person.** The execution engine already refuses, per
  item, a plan that may ask for an administrator password or may need a
  restart. A scheduled run has nobody to answer either.
- **Approval wins.** If the person asked MacUp to confirm every change with
  Touch ID, a scheduled run installs nothing and says so: a schedule cannot
  ask the device owner for anything.
- **Fail closed.** A configuration MacUp cannot read fully stops the run
  before it starts, and the setting itself defaults to off and is never
  inferred from a file MacUp could not parse.
- **Off by default, and visible.** `macup schedule enable` still installs a
  read-only check; installing takes `--install-updates`, or the switch in the
  app, and `macup schedule status` and the app both show the exact command
  launchd will run.
- **Evidence.** Every attempt and every skip is in the history, marked as a
  scheduled run, and the check is saved where `macup check --save-state`
  saves it, so the next time the app opens it can say what happened.
- **Still no daemon.** A per-user LaunchAgent, loaded into `gui/<uid>`, with
  no root, no privileged helper, and no process between runs.

The macOS provider is unchanged: it installs nothing, scheduled or not.

## ADR-024 — Doctor may fix what belongs to MacUp, and nothing else
The spec says Doctor should explain rather than automatically "fix
everything" (CLAUDE.md §13), and it still does. On 2026-10-07 the owner asked
for fix actions. The line drawn: a finding may carry **one** fix, and only
where the thing to change belongs to MacUp.

The four that exist:

- drop rules in MacUp's configuration naming software no provider reports as
  installed;
- forget a provider's configured executable path when it cannot be used (the
  tool itself is untouched, and MacUp resolves it the ordinary way again);
- install the launchd agent the configuration asks for;
- remove an installed agent the configuration no longer asks for.

What keeps it honest:

- **A closed list.** `DiagnosticFix.Action` is an enum, so a fix is never an
  arbitrary command and no check can invent one. No fix runs a package
  manager, changes a package, or needs an administrator.
- **Asked for, one at a time.** `macup doctor --fix <finding-id>` and the
  app's button both show what will change first, ask, and then go through the
  same approval gate as any other change. `--dry-run` changes nothing.
- **Re-checked immediately before acting.** A rule MacUp would drop has to
  still be in the file; a schedule it would install or remove has to still be
  what the configuration says; a configuration MacUp cannot read fully stops
  every fix. Anything else is reported, not forced.
- **Said only after looking.** "Removed" means the agent file is gone, not
  that MacUp asked for it to be.
- **Everything else still explains.** Two Homebrew installations, a PATH that
  differs from the login shell, an npm prefix that does not match its Node:
  these have no fix and keep saying what to do by hand, because MacUp is not
  confident enough to decide them for someone.

Doctor fixes are not in the update History, which records what MacUp did to
packages. A fix changes MacUp's own configuration file or its own launchd
agent: both are visible where they live, the result is printed or shown, and
`macup config show` and `macup schedule status` report the state afterwards.
