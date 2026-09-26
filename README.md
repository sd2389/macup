# MacUp — Claude Code Build Kit

MacUp is a local-first, open-source macOS developer-environment manager.

Its job is to help a user **understand, review, update, and maintain** the package managers, runtimes, CLI tools, and developer applications on their Mac without blindly changing the machine.

## Working product statement

> One place to understand, update, and maintain your Mac development environment.

## North star

MacUp should be **conservative with changes and aggressive with information**.

A user must be able to see:
- what MacUp detected,
- who manages each item,
- what is outdated,
- what MacUp proposes to do,
- the exact command it intends to execute,
- whether the action requires privilege/restart/approval,
- what succeeded or failed,
- and how to prevent an item from being touched again.

MacUp must never silently change something the user did not authorize.

## First release

v0.1 is intentionally narrow:
- Swift core
- Swift CLI
- SwiftUI desktop app
- Homebrew formulae + casks
- npm global packages
- mise-managed runtimes
- macOS software-update detection
- persistent package/provider policies
- read-only check mode
- dry-run plan
- explicit per-item updates
- update history
- basic Doctor
- no cloud
- no account
- no telemetry by default
- no arbitrary remote commands

Read `CLAUDE.md` first. It is the authoritative implementation brief.
