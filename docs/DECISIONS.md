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
