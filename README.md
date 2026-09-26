# MacUp

MacUp is a local-first, open-source macOS developer-environment manager.

Its job is to help a user **understand, review, update, and maintain** the package managers, runtimes, CLI tools, and developer applications on their Mac without blindly changing the machine.

> One place to understand, update, and maintain your Mac development environment.

MacUp is **conservative with changes and aggressive with information**. It is not a new package manager: it orchestrates Homebrew, npm, mise, and macOS software update, adds policy, planning, and diagnostics on top, and never silently changes something the user did not authorize.

## Status

Early development. **This version is read-only** (Phases 0 and 1 of the build plan): it detects providers and reports what is outdated, and cannot install, upgrade, or remove anything.

| Phase | Scope | State |
| --- | --- | --- |
| 0 | Package, command runner, config paths, CI | done |
| 1 | Read-only engine: Homebrew, npm, mise, macOS; `macup check` | done |
| 5a | Read-only desktop app (pulled forward) | done |
| 2 | Policies and dry-run planning | next |
| 3 | Safe per-item updates, verification, history | planned |
| 4–7 | Doctor, full app controls, launchd scheduling, release hardening | planned |

## Try it

Requires macOS 14+ and Xcode 16.3+ or the matching Command Line Tools.

```bash
swift build
.build/debug/macup check
```

`macup check` never changes anything. Other read-only commands:

```bash
.build/debug/macup check --verbose       # ownership, risk reasons, every command run
.build/debug/macup check --json          # versioned machine-readable report
.build/debug/macup provider list         # which installation of each tool MacUp uses
.build/debug/macup config show           # configuration in effect, and any problems
```

The desktop app shows the same information in a native window and the menu bar:

```bash
scripts/build-app.sh && open build/MacUp.app
```

`macup check --refresh` first runs `brew update` (which updates Homebrew itself and its package lists, but no installed packages) and a fresh `softwareupdate --list` scan.

Example output (illustrative):

```text
MacUp check · read-only · nothing was changed

Homebrew 4.5.0 · /opt/homebrew/bin/brew
  Prefix: /opt/homebrew
  142 installed · 2 updates
  brew:git    2.49.0 → 2.50.0    minor · moderate risk
  brew:mysql  9.3.0 → 9.4.0      minor · moderate risk

npm 11.4.2 · ~/.local/share/mise/installs/node/24.3.0/bin/npm
  Node v24.3.0 · ~/.local/share/mise/installs/node/24.3.0/bin/node · managed by mise
  Global packages: ~/.local/share/mise/installs/node/24.3.0/lib/node_modules
  3 installed · 1 update
  npm:@anthropic-ai/claude-code  2.1.282 → 2.1.283  patch · low risk

mise 2026.7.3 · ~/.local/bin/mise
  Global config: ~/.config/mise/config.toml
  2 installed · up to date

macOS 15.5 · /usr/sbin/softwareupdate
  1 update
  macos:macOS Sequoia 15.6-24G84  15.5 → 15.6  minor · high risk · restart required

4 updates available (Homebrew 2, npm 1, macOS 1).
Nothing was changed.
```

## Trust contract (highlights)

- Read-only commands never install, upgrade, remove, clean, prune, or rewrite configuration — enforced by a command allowlist, not just convention.
- External programs run with an executable path and an argument array; never through a shell.
- Homebrew runs with `HOMEBREW_NO_AUTO_UPDATE=1`, so a check never updates Homebrew behind your back.
- Providers get an allowlisted environment; secrets are redacted from anything displayed.
- No account, no cloud, no telemetry.

See [docs/TRUST_AND_SECURITY.md](docs/TRUST_AND_SECURITY.md). To report a vulnerability, please use private reporting as described in [SECURITY.md](SECURITY.md).

## Documentation

- [CLAUDE.md](CLAUDE.md) — the authoritative implementation brief (read first)
- [docs/CLI.md](docs/CLI.md) — commands, exit codes, JSON schema
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) — config file, validation, storage
- [docs/COMMAND_EXECUTION.md](docs/COMMAND_EXECUTION.md) — command runner, environment, executable resolution, read-only guard
- [docs/PROVIDER_NOTES.md](docs/PROVIDER_NOTES.md) — exactly what each provider runs
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — building and testing
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/PRODUCT_SPEC.md](docs/PRODUCT_SPEC.md), [docs/UX_SPEC.md](docs/UX_SPEC.md), [docs/PROVIDER_SPEC.md](docs/PROVIDER_SPEC.md), [docs/TEST_PLAN.md](docs/TEST_PLAN.md), [docs/ROADMAP.md](docs/ROADMAP.md), [docs/DECISIONS.md](docs/DECISIONS.md), [docs/RELEASE.md](docs/RELEASE.md)
- [docs/IMPLEMENTATION_CHECKLIST.md](docs/IMPLEMENTATION_CHECKLIST.md) — phase checklists

`MACUP_MASTER_BUILD_SPEC.md` is the single-file specification these documents were extracted from.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
