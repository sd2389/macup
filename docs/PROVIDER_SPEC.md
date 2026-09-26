# Provider Specification

Providers are adapters, not independent mini-apps.

## Common provider rules

Each provider must:
- identify its binary
- report version/status
- inventory managed items where feasible
- return outdated candidates
- construct exact execution plans
- expose capabilities
- verify post-update state
- never bypass the central policy engine
- never silently update as part of `check`

## Homebrew

Read/check:
- prefer documented JSON CLI output
- `brew outdated --json=v2`
- distinguish formulae and casks

Update:
- one selected item at a time
- never blanket `brew upgrade` when policy exclusions exist
- no automatic cleanup
- preserve pins
- show when an action can update dependents

Provider ownership:
- record exact brew path
- report multiple installations

## npm global

Read/check:
- global only
- use JSON-capable npm commands
- record npm path, node path, prefix, versions
- parse scoped names

Update:
- selected package only
- exact argument array
- verify resulting installed version

Special:
- npm global packages depend on active Node/prefix
- ownership chain should be visible
- provider non-zero statuses with valid JSON must be handled according to documented behavior rather than treated as parse failure automatically

## mise

Read/check:
- use `mise outdated --json`
- preserve configured range by default
- separate global from local project configs

Update:
- no automatic `--bump`
- no automatic prune
- dry-run capability should be used to improve planning where useful
- explicitly show possible config/lockfile changes

Global maintenance:
- do not traverse and rewrite project configurations in v0.1

## macOS

v0.1 is informational:
- list available updates
- show version/title/restart indicators when parseable
- parser behind fixtures
- no install/restart

## Future providers

Candidates after v1:
- uv
- pipx
- Cargo
- RubyGems
- VS Code extensions
- App Store through an optional supported mechanism
- Docker Desktop/tooling
- GitHub CLI extensions

Do not add these until core contracts are stable.
