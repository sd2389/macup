# Provider implementation notes

What each provider runs, what it reads, and what it deliberately does not
do. Output formats were confirmed against the tools installed on the
development machine (macOS 27.0, Homebrew 7.0.6, npm 10.9.8 and 11.17.0,
mise 2026.7.3) and their `--help`; parsers tolerate older and newer shapes
noted below. Fixtures live in `Tests/MacUpCoreTests/Fixtures/`.

## Homebrew (`homebrew`)

| Purpose | Command |
| --- | --- |
| Detect | `brew --version`, `brew --prefix` |
| Candidates | `brew outdated --json=v2` |
| Inventory | `brew info --json=v2 --installed` |
| Refresh (`--refresh` only) | `brew update` |

- Every invocation sets `HOMEBREW_NO_AUTO_UPDATE=1`. Homebrew's own
  `utils/auto-update.sh` lists `install`, `outdated`, `upgrade`, `bundle`,
  and `release` as commands that run `brew update` first; a normal check
  must not update Homebrew.
- Formula names are Homebrew's full names (`user/tap/formula` for
  third-party taps); cask names are tokens. IDs: `brew:<name>`,
  `brew-cask:<token>`.
- `installed_versions` may be a string or an array; the highest comparable
  version is shown. `pinned`/`pinned_version` are optional (casks gained
  them in newer Homebrew). Pinned items are high risk and noted; MacUp
  never unpins.
- Without `--greedy`, `brew outdated` skips casks that update themselves or
  use `version :latest`; MacUp keeps Homebrew's default.
- From the inventory: casks with `pkg`/`installer` artifacts get the
  "may require administrator authorization" signal; formulae installed as
  dependencies get "may affect dependents".
- Never: `brew upgrade` (blanket or otherwise), `brew cleanup`,
  `brew pin`/`unpin`.

## npm global packages (`npm`)

| Purpose | Command |
| --- | --- |
| Detect | `npm --version`, `node --version`, `npm prefix -g`, `npm root -g` |
| Candidates | `npm outdated -g --json` |
| Inventory | `npm ls -g --json --depth=0` |

- Global scope only; projects are never scanned.
- `npm outdated` exits 1 when updates exist. Exit statuses 0 and 1 with
  valid JSON are success; npm's JSON error objects (`{"error": {"code":
  …}}`) become clear errors (`ENOENT`, `EACCES`/`EPERM`, network codes,
  `E401`/`E403`); other statuses are failures.
- `npm ls` exits 1 when it finds problems but still prints the tree; the
  problems become a finding.
- The available version is `latest` (global packages have no version
  range); when `wanted` differs it is noted.
- An installed version newer than `latest` (for example a pre-release) is
  a finding, not an update. A package whose `location` lies outside
  `npm root -g` is skipped as ambiguous ownership.
- If `npm root -g` does not exist there are no global packages, and MacUp
  does not ask npm (which would fail with `ENOENT`).
- Ownership: `npm <version> → Node <version> → <manager>`, where the
  manager (mise, Homebrew, nvm, Volta, fnm, asdf, nodenv, n) is inferred
  from paths and shown as a hint only.
- Updating npm itself is flagged, naming the tool that manages Node.

## mise (`mise`)

| Purpose | Command |
| --- | --- |
| Detect | `mise --version` |
| Candidates | `mise outdated --json` |
| Inventory | `mise ls --json` |

- Commands run with the home directory as the working directory, so a
  check sees global and home-directory configuration rather than whatever
  project the shell is in.
- `--bump` is never used: without it, `latest` is the newest version that
  matches the requested version, so the configuration does not change.
- Each candidate records the config file that requests the tool and its
  scope: `global` (mise's config directory), `system` (`/etc/mise`), `home`
  (config files directly under the home directory), `project` (labelled
  informational), or `unknown`.
- Exact pins that still show a newer version are flagged as needing a
  config change. A `mise.lock` next to the config is flagged as possibly
  changing.
- Node updates warn that global npm packages are installed per Node
  version.
- Older output (`{"tool": {"requested", "current", "latest"}}` without
  `name`, `bump`, `source`) still parses. A requested but missing tool is a
  finding.
- Never: `mise upgrade`, `mise install`, `mise prune`, `mise self-update`,
  `mise trust`, `mise use`.

## macOS (`macos`)

| Purpose | Command |
| --- | --- |
| Detect | none — the OS version and build come from `sysctl` |
| Candidates | `/usr/sbin/softwareupdate --list --no-scan` |
| Candidates with `--refresh` | `/usr/sbin/softwareupdate --list` (a fresh scan; the read-only guard treats it as a metadata refresh) |

- Detection only in v0.1: never `--install`, `--download`, `--background`,
  or anything requiring a password.
- Parses the macOS 11+ format (`* Label: …` followed by
  `Title: …, Version: …, Size: …KiB, Recommended: YES, Action: restart,`).
  Fields are split only at `, Key: ` boundaries so titles containing commas
  survive. "No new software available." arrives on stderr and is handled.
- Unrecognized or legacy output is a parse error; an entry without details
  is a finding, and the result is marked incomplete (never "up to date").
  If updates are listed but none can be read, that is a parse error.
  Ambiguity never becomes fabricated state.
- IDs are `macos:<label>` — the label is the identifier `softwareupdate`
  itself uses.
- OS updates carry `operatingSystemUpdate` (high risk) and, when the action
  is restart or shut down, `restartRequired`. Beta titles and updates Apple
  does not mark as recommended are noted.
- Output is parsed in English; a localized `softwareupdate` would produce
  a parse error rather than wrong results.
