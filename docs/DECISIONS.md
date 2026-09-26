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
