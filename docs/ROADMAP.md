# Roadmap

## v0.0.1 — Foundation
- package structure
- core models
- command runner abstraction
- config
- tests
- CI

## v0.1.0 — Read-only Alpha
- Homebrew check
- npm global check
- mise check
- macOS update detection
- unified CLI
- `--json`
- no modification

## v0.2.0 — Policy + Planning
- Auto / Ask / Ignore / Pin / Inherit
- provider enable/disable
- dry-run
- execution plans
- exact command review

## v0.3.0 — Controlled Updates
- selected Homebrew updates
- selected npm global updates
- conservative mise updates
- verification
- history

## v0.4.0 — Doctor
- path/provider conflicts
- ownership chains
- config diagnostics

## v0.5.0 — Native App
- dashboard
- updates
- policy UI
- plan review
- doctor
- history
- settings
- menu bar

## v0.6.0 — Scheduling
- launchd
- scheduled check
- explicit-auto-only updating
- notifications

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
