# Roadmap

Only v0.1.0 has been released. Everything marked **done** below is in `main`
and covered by tests; nothing after v0.1.0 has been tagged. The one honest
summary of where MacUp is: it can now plan and perform per-item updates for
Homebrew, npm, and mise, and it still applies no macOS update, schedules no
update, and offers no rollback.

## v0.0.1 — Foundation — done
- package structure
- core models
- command runner abstraction
- config
- tests
- CI

## v0.1.0 — Read-only Alpha — released 2026-09-26
- Homebrew check
- npm global check
- mise check
- macOS update detection
- unified CLI
- `--json`
- no modification

## v0.1.1 — Scheduled read-only checks — done, unreleased
- `macup schedule enable|disable|status`
- launchd user agent (no daemon, no root)
- `macup check --save-state`
- brought forward from v0.6.0: a scheduled *check* needs neither the policy
  engine nor the execution engine, so it did not have to wait for them

## v0.2.0 — Policy + Planning — done, unreleased
- Auto / Ask / Ignore / Pin / Inherit, with precedence per item, then
  provider, then global default
- provider enable/disable
- dry-run that launches nothing
- execution plans carrying the exact executable and argument array
- exact command review
- a single editing path (`PolicyEditor`) shared by both surfaces

## v0.3.0 — Controlled Updates — done, unreleased
- selected Homebrew updates (formula and cask, one named item at a time)
- selected npm global updates (one package, at a named version)
- conservative mise updates (within the requested range; never `--bump`)
- the policy re-read immediately before each item
- execution bounded by the reviewed plan and the reviewed command rules
- verification by the owning provider, reported honestly
- history of every attempt and every skip
- cancellation

Not in this version, and not pretended otherwise: rollback. Every plan
reports it as unavailable.

## v0.4.0 — Doctor — done, unreleased
- provider availability and results
- multiple Homebrew installations and a non-standard prefix
- executable architecture, from the Mach-O header
- login-shell `PATH` against MacUp's own
- runtime ownership: which installation of a runtime actually runs
- npm ownership: which Node owns the global packages
- configuration diagnostics, including stale item policies
- MacUp's own directories: usable, private, owned by you
- whether a configured schedule is really installed and loaded

Doctor explains. It has no fix action, deliberately.

## v0.5.0 — Native App — in progress
- dashboard — done (v0.1.0)
- updates — done, read-only in v0.1.0
- doctor — done (Doctor engine in v0.4.0)
- history — done
- settings and a Features screen — done
- menu bar — done
- policy UI and plan review — ship with v0.2.0 and v0.3.0; see
  `docs/CLI.md` for the matching commands
- Xcode project, asset catalog, and SwiftUI previews — still waiting on Xcode

## v0.6.0 — Scheduled updating — not started
- explicit-auto-only updating on a schedule
- notifications (needs the app bundle: a bare CLI cannot post one)
- battery, metered-network, and quiet-hours awareness
- the scheduled read-only check itself shipped in v0.1.1

The engine already distinguishes an unattended run from an interactive one:
an unattended run touches only items that resolve to `auto`, and refuses
anything that may ask for a password or a restart. What does not exist yet is
a scheduled job that performs updates at all, or any notification.

## v0.9.0 — Public Beta
- security review
- accessibility
- packaging
- crash hardening
- docs

## v1.0.0 — Stable
- signed/notarized release
- checksums
- stable config migration path
- documented machine-readable CLI schema

## Post-v1
Only after evidence of demand:
- uv/pipx/Cargo/etc.
- snapshots
- limited rollback strategies where technically sound
- environment export/restore
- cloud sync
- team policy
- fleet visibility

Cloud must never introduce arbitrary remote shell execution.
