# Architecture

## High-level

```text
                 ┌─────────────────┐
                 │   MacUp.app     │
                 │ SwiftUI/MenuBar │
                 └────────┬────────┘
                          │
┌──────────────┐   ┌──────▼────────┐
│  macup CLI   │──►│   MacUpCore   │
└──────────────┘   └──────┬────────┘
                          │
                  ┌───────▼────────┐
                  │ Policy + Plan  │
                  └───────┬────────┘
                          │
                  ┌───────▼────────┐
                  │ ExecutionEngine│
                  └───────┬────────┘
                          │
             ┌────────────┼─────────────┐
             │            │             │
          Homebrew       npm          mise
             │            │             │
             └────────────┼─────────────┘
                          │
                    macOS provider
```

## Boundary rules

### UI
Displays state and sends intents. No provider-specific shell logic.

### CLI
Parses commands and presents output. No duplicated provider policy logic.

### Core
Owns models, policy, planning, provider interfaces, execution, verification, diagnostics, history.

### Provider
Translates provider-specific machine state into MacUp models and constructs provider-specific plans.

### CommandRunner
The only normal path for launching external executables.

### Scheduler
Owns the launchd user agent that runs a scheduled check: building the property
list, loading and unloading it through `launchctl`, and reporting what is
actually installed. It is a user agent, never a daemon, and the only command it
can schedule is `macup check`. The label (`com.macup.check`) and the agent path
are MacUp's own constants, so no part of the `launchctl` invocation comes from
user text.

## Data flow

### Check
```text
detect providers
  -> inventory/outdated concurrently
  -> normalize candidates
  -> evaluate current policy
  -> present
```

### Update
```text
select candidates
  -> generate plans
  -> present plan
  -> obtain/confirm authorization
  -> re-read policy
  -> execute sequentially or with conservative bounded concurrency
  -> verify
  -> record history
```

Avoid concurrent modifications by default. Checks may run concurrently; upgrades should start sequentially unless a provider is explicitly proven safe for parallel execution.

## Binary resolution

Do not blindly trust GUI PATH.

Resolve provider binaries using (docs/COMMAND_EXECUTION.md has the details):
1. configured explicit path if valid — and nothing else when one is set
2. the user's `PATH` (the CLI's own; for the GUI, discovered from the login shell)
3. standard package-manager locations, only when root or the user controls them

Record and display the chosen path.

If conflicting installations are found, Doctor reports them.

## Configuration

Config is versioned and atomically written.

Recommended directories:
- config: `~/.config/macup/`
- history/cache: appropriate Application Support or `~/.local/state/macup/` if CLI-first, but choose one canonical scheme and document it
- GUI must use the same source of truth as CLI

Before public release, align with macOS conventions while keeping CLI behavior intuitive.

## Concurrency

Use structured concurrency for independent read-only checks.

Use actors where shared mutable state exists:
- history writer
- in-memory provider status store
- execution coordinator if needed

No unbounded task creation.

## Error model

Do not reduce everything to strings.

Create typed categories:
- providerUnavailable
- commandFailed
- parseFailed
- policyDenied
- authorizationRequired
- timeout
- cancelled
- verificationFailed
- ambiguousOwnership
- unsupported
- configurationInvalid

Attach display-safe details separately.

## Version comparison

Do not assume SemVer.

Implement:
- semantic comparison when parseable and appropriate
- provider-supplied comparison/metadata when available
- opaque current/target strings otherwise

Risk logic must tolerate opaque versions.
