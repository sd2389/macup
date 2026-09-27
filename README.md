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
| 6a | Scheduled read-only checks (pulled forward) | done |
| 4–7 | Doctor, full app controls, scheduled updating, release hardening | planned |

## Command-line tool

Install with Homebrew (needs macOS 14+ and the Xcode Command Line Tools:
`xcode-select --install`; the formula builds MacUp from source):

```bash
brew install sd2389/macup/macup
```

Or build it from a clone, which puts `macup` in `~/.local/bin`:

```bash
git clone https://github.com/sd2389/macup.git
cd macup
make install
```

Then:

```bash
macup                    # see what's outdated
macup check --verbose    # who manages each item, why it's rated that way, every command run
macup check --json       # machine-readable output for scripts
macup providers          # which installation of each tool MacUp uses
macup config             # the settings MacUp is using
macup schedule           # whether MacUp checks on its own
```

Nothing is ever changed: this version only reports. Remove the command with
`brew uninstall macup` or, for a clone install, `make uninstall`;
`make install PREFIX=/usr/local` installs it elsewhere.

## Desktop app

The same information in a native window and the menu bar:

```bash
make app && open build/MacUp.app
```

`macup check --refresh` first runs `brew update` (which updates Homebrew itself and its package lists, but no installed packages) and a fresh `softwareupdate --list` scan.

## Asking before it changes anything

```bash
macup security require on   # Touch ID before MacUp changes the schedule
macup security              # which sensor this Mac has
```

macOS does the asking with whatever the Mac has — Touch ID, Face ID, or Optic
ID — falling back to your password or Apple Watch. MacUp never sees your
fingerprint, your face, or your password. The same switch is on the app's
**Features** screen.

It is a confirmation, not a lock: MacUp runs as you, and so do `brew`, `npm`,
and `mise`. What it buys is a deliberate step in front of every change MacUp
itself makes.

MacUp also has a camera face match of its own, off by default
(`macup security face enroll`, or Features → Face match). No Mac has a Face
ID sensor, and macOS exposes
no face-recognition API, so this compares how alike two pictures look — **a
photograph of you passes it**. It can only approve early; when it does not
match, MacUp still asks macOS. Treat it as a shortcut, not as security.

## Checking on a schedule

```bash
macup schedule enable --time 09:00   # or --frequency weekly --weekday monday
macup schedule                       # when it next runs, what it last found
macup schedule disable               # removes it completely
```

This installs a launchd **user agent** that runs `macup check --save-state`
at that time — as you, not as root, with no background process between runs
and no administrator authorization. The scheduled run is the same read-only
check, so it still changes nothing; scheduled *updating* does not exist yet.
Results land in `~/.local/state/macup/last-check.json`.

The app has the same control on its **Features** screen: one row per feature,
one switch each — automatic checks, approval, and face match. The Dashboard
and the menu bar show when the next check is due. Settings stays what it is:
where the configuration lives and what is in it.

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
