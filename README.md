# MacUp

MacUp is a local-first, open-source macOS developer-environment manager.

Its job is to help a user **understand, review, update, and maintain** the package managers, runtimes, CLI tools, and developer applications on their Mac without blindly changing the machine.

> One place to understand, update, and maintain your Mac development environment.

MacUp is **conservative with changes and aggressive with information**. It is not a new package manager: it orchestrates Homebrew, npm, mise, and macOS software update, adds policy, planning, and diagnostics on top, and never silently changes something the user did not authorize.

## Status

Early development. v0.1.0 is the only tagged release; everything below marked
done is in `main` and covered by tests. The build reports 0.4.0, which is the
version of the code rather than of a release.

MacUp can now plan and perform **per-item** updates for Homebrew, npm, and
mise — one named package at a time, from a plan you read first, with the
policy re-checked immediately before the command runs and the result recorded
in history.

| Phase | Scope | State |
| --- | --- | --- |
| 0 | Package, command runner, config paths, CI | done |
| 1 | Read-only engine: Homebrew, npm, mise, macOS; `macup check` | done |
| 2 | Policies, planning, dry run, exact command review | done |
| 3 | Per-item updates, verification, history, cancellation | done |
| 4 | Doctor: eleven deterministic diagnostics | done |
| 5a | Desktop app: dashboard, updates, doctor, history, settings, menu bar | done |
| 6a | Scheduled read-only checks | done |
| 5b | Xcode project, asset catalog, SwiftUI previews | waiting on Xcode |
| 6b | Scheduled *updating* (explicit-auto only) and notifications | not started |
| 7 | Release hardening: signing, notarization, packaging, beta | not started |

### What MacUp still will not do

Being exact about this is the point of the project, so it gets its own list.

- **Apply a macOS update.** MacUp reports them. Installing one needs an
  administrator and usually a restart; MacUp holds no password and restarts
  nothing.
- **Roll back.** No provider action has a tested rollback strategy, so every
  plan reports rollback as unavailable rather than promising one.
- **Update on a schedule.** A scheduled check is read-only. Scheduled
  updating does not exist yet.
- **Notify you.** Not yet; it needs the app bundle.
- **Run `brew cleanup`, `mise prune`, or anything else that deletes.** After
  an upgrade the version you were on is still installed.
- **Unpin something you pinned** in Homebrew.
- **Upgrade everything with one command.** Every command names one item,
  because an upgrade that names nothing walks past every exclusion.
- **Use `sudo`, or ask you for a password.** Where a change genuinely needs
  one, the plan says so and the provider does the asking.

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

Then, to look:

```bash
macup                    # see what's outdated. Reads only; changes nothing
macup check --verbose    # who manages each item, why it's rated that way, every command run
macup check --json       # machine-readable output for scripts
macup doctor             # why this Mac behaves the way it does
macup providers          # which installation of each tool MacUp uses
macup config             # the settings MacUp is using
macup schedule           # whether MacUp checks on its own
```

And to change something:

```bash
macup plan               # every update MacUp would make, with the exact commands
macup update --dry-run   # the same, and it runs nothing
macup update brew:git    # update one named item
macup history            # what MacUp attempted, and what happened
```

`macup` on its own is a read-only check. Only `macup update` changes
anything, and it changes only what a plan named and policy allowed. See
[docs/CLI.md](docs/CLI.md) for the full command surface, the flags, the exit
codes, and the JSON schemas.

Remove the command with `brew uninstall macup` or, for a clone install,
`make uninstall`; `make install PREFIX=/usr/local` installs it elsewhere.

## Deciding what MacUp may touch

Every item has a policy, resolved per item, then per provider, then from your
global default:

| Policy | Meaning |
| --- | --- |
| `auto` | Update without asking — unless risk says otherwise (see below) |
| `ask` | Ask First. The default |
| `ignore` | Never update, and never offer to |
| `pin` | Hold at the current version |
| `inherit` | Use the provider's rule, or the global default |

```bash
macup policy list
macup policy set brew:postgresql ignore
macup policy set npm:@anthropic-ai/claude-code auto
macup policy clear brew:postgresql
macup policy skip brew:mysql        # not this version; the next one comes back by itself
macup policy note brew:php "waiting for PHP 8.4 support"
macup provider disable mise
```

`auto` means "update this without asking me", not "decide anything on my
behalf". An `auto` item still waits for a person when the change is a macOS
update, may ask for an administrator password, may require a restart, would
rewrite a config file or lockfile, is a major runtime change, or has a risk
MacUp could not judge. A scheduled run has nobody to ask, so it updates only
items that resolve to `auto` and skips the rest as review items.

Every decision comes with a sentence saying which rule produced it, so a plan
that lists twenty skipped items says why each one was skipped.

The app has the same controls, on the Updates and Settings screens — both
surfaces go through the same `MacUpCore`, so they cannot disagree.

## Site

`site/` holds the project's landing page: one static page, no build step, using
real screenshots captured from the app. Preview it with
`python3 -m http.server 4173 --directory site`.

## Desktop app

The same engine in a native window and the menu bar — Dashboard, Updates,
Doctor, History, Features, and Settings:

```bash
make app && open build/MacUp.app
```

Every feature ships in both surfaces in the same change, and the app uses
`MacUpCore` only: no provider or policy logic lives in the UI. The local
bundle is ad-hoc signed because this repository has no Developer ID
certificate, which is why MacUp's own camera face match cannot capture in a
local build — [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) explains why, and the
app's Features screen says so too.

`macup check --refresh` first runs `brew update` (which updates Homebrew itself and its package lists, but no installed packages) and a fresh `softwareupdate --list` scan.

## Asking before it changes anything

```bash
macup security require on   # Touch ID before MacUp changes anything
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

- **MacUp runs only the commands it showed you.** While a plan runs, the
  command runner is wrapped in a guard that compares every invocation against
  that plan's own steps — executable, argument array, and effect. Anything
  else is refused before it reaches the operating system.
- **A change also has to be a shape MacUp has reviewed.** Four modifying
  command shapes exist, in one file, and each was confirmed against the
  tool's own `--help`. Being in a plan is not by itself permission to run
  something nobody vetted.
- **Every command names one item.** `brew upgrade` with no formula upgrades
  everything, so the rules require an exact argument count — naming too few
  is the dangerous case.
- **Your policy is re-read immediately before the command runs**, from the
  file, not from the copy the plan was built with. An exclusion you added
  after reviewing the list is the one that wins.
- **A configuration MacUp cannot read allows nothing**, because the rules
  saying which items you excluded are exactly the ones it could not read.
- **Read-only commands cannot act.** Their allowlist permits no positional
  arguments at all, so a check has no way to name a package.
- External programs run with an executable path and an argument array; never
  through a shell. A hostile package name is one inert array element.
- Homebrew runs with `HOMEBREW_NO_AUTO_UPDATE=1`, and an upgrade additionally
  with `HOMEBREW_NO_INSTALL_CLEANUP=1` and
  `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1` — neither of which has a
  command-line flag, which is why the owning provider supplies the
  environment rather than the engine assembling one.
- **Failures stop the run short of the risky changes.** After a failure MacUp
  no longer knows the state of your machine as well as it did when the plan
  was written, so it skips the remaining high-risk and unjudged items.
- **History records every attempt and every skip, with the reason** — and
  refuses to record secrets, or a dry run, or a guess about a line it cannot
  read back.
- Providers get an allowlisted environment; secrets are redacted from
  anything displayed.
- No account, no cloud, no telemetry.

Each of these is a property of the code rather than a promise about it.
[docs/TRUST_AND_SECURITY.md](docs/TRUST_AND_SECURITY.md) says which type
enforces which one. To report a vulnerability, please use private reporting as
described in [SECURITY.md](SECURITY.md).

## Documentation

- [CLAUDE.md](CLAUDE.md) — the authoritative implementation brief (read first)
- [docs/TRUST_AND_SECURITY.md](docs/TRUST_AND_SECURITY.md) — what must be true before MacUp changes anything, and the threat model
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — the update pipeline, the two allowlists, and why the provider supplies the environment
- [docs/CLI.md](docs/CLI.md) — commands, exit codes, JSON schema
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) — config file, validation, storage, editing policy
- [docs/COMMAND_EXECUTION.md](docs/COMMAND_EXECUTION.md) — command runner, environment, executable resolution, read-only guard
- [docs/PROVIDER_NOTES.md](docs/PROVIDER_NOTES.md) — exactly what each provider runs, plans, and verifies
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — building and testing
- [docs/TEST_PLAN.md](docs/TEST_PLAN.md) — what the suite covers, and what it deliberately does not
- [docs/PRODUCT_SPEC.md](docs/PRODUCT_SPEC.md), [docs/UX_SPEC.md](docs/UX_SPEC.md), [docs/PROVIDER_SPEC.md](docs/PROVIDER_SPEC.md), [docs/ROADMAP.md](docs/ROADMAP.md), [docs/DECISIONS.md](docs/DECISIONS.md), [docs/RELEASE.md](docs/RELEASE.md)
- [docs/IMPLEMENTATION_CHECKLIST.md](docs/IMPLEMENTATION_CHECKLIST.md) — phase checklists

`MACUP_MASTER_BUILD_SPEC.md` is the single-file specification these documents were extracted from.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
