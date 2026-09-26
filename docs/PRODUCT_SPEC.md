# Product Specification

## Problem

A modern developer Mac can contain several independent update ecosystems. Users must remember:
- which package manager owns which tool,
- which command checks or upgrades it,
- which runtime a global tool belongs to,
- which updates are safe to automate,
- and which updates should be held back.

The result is fragmented maintenance and risky “update everything” scripts.

## Product

MacUp provides one trustworthy interface over those systems.

It answers:
1. What is installed?
2. Who manages it?
3. What is outdated?
4. What would change?
5. What is allowed to change?
6. What command will be run?
7. Did the update actually succeed?
8. What changed historically?
9. Is my developer environment misconfigured?

## Primary jobs to be done

### Understand
“Tell me what manages my tools and runtimes.”

### Review
“Show me what is outdated without changing anything.”

### Control
“Never update PostgreSQL automatically, always ask before Claude Code, and ignore mise.”

### Update
“Update only the items I approve.”

### Diagnose
“Why do I have multiple Node/Python/npm environments and which one am I using?”

### Maintain
“Check regularly and only auto-update things I explicitly permit.”

## Principles

- user control over convenience
- explanation before execution
- local first
- no hidden privilege
- provider-native actions
- fail closed
- open source
- native macOS UX
- useful without an account
- predictable over clever

## Personas

### Developer
Homebrew + mise + npm + Docker + editors/CLI tools.

### Power user
Many GUI apps and command-line tools; wants a consolidated update view.

### Team developer (future)
Needs machine consistency and policy, but this is not v1.

## MVP success criteria

A new user can install MacUp and within minutes:
- see detected providers,
- see outdated items,
- understand ownership,
- mark items Ask/Ignore/Auto,
- review exact commands,
- safely update selected items,
- inspect history,
- run Doctor,
- schedule checks.

## Metrics for later product validation

Do not add telemetry merely to collect these. Use opt-in methods, GitHub signals, or anonymous metrics only after a privacy design.

Potential measures:
- installs/releases downloaded
- GitHub stars
- repeat users
- update success rate
- provider parse-error rate
- issue volume by provider
- number of outside contributors
- percentage of users enabling scheduling (if explicitly measured)
