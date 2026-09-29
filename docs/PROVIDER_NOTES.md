# Provider implementation notes

What each provider runs, what it reads, what it plans, how it confirms the
result, and what it deliberately does not do.

Output formats were confirmed against the tools installed on the development
machine (macOS 27.0, Homebrew 7.0.6, npm 10.9.8 and 11.17.0, mise 2026.7.3);
parsers tolerate older and newer shapes noted below. Fixtures live in
`Tests/MacUpCoreTests/Fixtures/`.

**The modifying command shapes were confirmed against each tool's own help
— `brew help upgrade`, `mise upgrade --help`, and `npm help install` — not
from memory.** That was not a formality: reading the help changed real
decisions, and each one is recorded below next to the command it changed.
CLAUDE.md §26 rule 5 requires it, and a provider command MacUp invented would
be a provider command nobody could check.

Every modifying command names exactly one item. That is not a performance
choice. `brew upgrade` and `mise upgrade` with no arguments upgrade everything
the tool considers outdated, and `npm install -g` with no package installs
the working directory as a global package. Naming the item is what makes an
exclusion mean anything, which is why `ModifyingCommandRule` fixes the
positional count exactly rather than as an upper bound.

The shapes below, and nothing else, are what `ModifyingCommandRules.all`
permits. `ExecutionGuard` additionally requires that the command appear in the
plan the user reviewed; see `docs/ARCHITECTURE.md`.

Verification re-runs each provider's own read-only inventory. Those commands
are already on the check allowlist and **none of them names a package**, so
verification cannot become a command that touches something else. Nor can it
refresh metadata: the rules verification is given are filtered to read-only,
so `brew update` is out of reach even though a check with `--refresh` may run
it. A version that did not move is reported as `targetNotReached`, output
MacUp could not parse as `failed`; neither is rounded up to success.

## Homebrew (`homebrew`)

Capabilities: detect, inventory, outdated, refreshMetadata, planUpdates,
verifyUpdates, listDependents.

| Purpose | Command |
| --- | --- |
| Detect | `brew --version`, `brew --prefix` |
| Candidates | `brew outdated --json=v2` |
| Inventory | `brew info --json=v2 --installed`, with `brew services list --json` beside it |
| Refresh (`--refresh` only) | `brew update` |
| What depends on a formula (asked for only) | `brew uses --installed --formula <name>`, `brew uses --installed --cask <name>` |
| Update a formula | `brew upgrade --formula --yes <name>` |
| Update a cask | `brew upgrade --cask --yes <token>` |
| Verify | `brew info --json=v2 --installed` |

### Services, dependents, and what an update affects

Confirmed against Homebrew 7.0.6's own source (`cmd/services.rb`,
`services/subcommand/list.rb`, `cmd/uses.rb`, `cmd/link.rb`,
`cli/named_args.rb`, `caveats.rb`):

- **`brew services list --json` only lists.** It prints `name`, `status`,
  `user`, `file`, and `exit_code` for every installed formula that defines a
  service (`[]` when none do); `status` is `started`, `scheduled`, `stopped`,
  `none` (not registered with launchd), `error`, `unknown`, or `other`.
  On an older Homebrew the command came from the homebrew/services tap, and
  running it without the tap makes Homebrew clone the tap first, so MacUp
  runs it only when `Library/Homebrew/cmd/services.rb` (built in) or the
  tapped command file exists. Otherwise, or when the command fails or prints
  something unreadable, formulae that define a service (`service` in
  `brew info`) are marked unknown — never "not running" — with a
  `homebrew.servicesUnreadable` finding.
- **An upgrade does not restart a service.** Homebrew's own caveat says to
  run `brew services restart` afterwards, and a service's launchd job starts
  it through `opt/<name>`, which the upgrade points at the new version. So a
  running service keeps the old version until it next starts — a restart, a
  login, a reboot — and then runs the new one. A formula running now carries
  `runsAsService` (moderate) and a note saying to restart it yourself.
- **Databases** (`mysql`, `mariadb`, `percona-server`, `postgresql`,
  `mongodb-community`, `redis`, `valkey`, any `@` version, any tap) moving to
  a new major version carry `mayMigrateData` (high, and always Ask First
  whatever `confirmMajorUpdates` says) and a note to back up first, because
  the new version may convert the data files the first time it starts. For
  these, a new second number counts as a new major version (MySQL 8.0 → 8.4,
  Redis 7.2 → 7.4), except PostgreSQL, whose first number is its major
  version. A change MacUp cannot classify is treated as possibly major.
- **`brew uses --installed` is read-only but slow**: it reads the install
  record of every installed formula and answers with everything that needs
  the formula at run time, directly or through another formula. It is on its
  own allowlist, `CommandAllowlist.dependentsLookup`, the only read-only
  rules that take a positional (exactly one, checked like a modifying
  command's), and only `macup dependents` and the app's Show What Depends on
  It use it; a check's allowlist cannot run it. A name Homebrew does not know
  gives a warning and an empty answer with exit status 0, so an empty answer
  with a warning is reported as "could not tell", not "nothing".
- **`brew link` links the newest version folder**, whatever state it is in,
  and points `opt/<name>` at it. After an interrupted upgrade that is the
  unfinished folder, which is why Doctor's `homebrew.unfinishedInstall`
  repair moves that folder to the Trash first and links second.

### What `brew help upgrade` changed

- **`--yes` is passed.** Homebrew's ask mode is now the default, and MacUp's
  subprocesses have no terminal to answer from. The confirmation belongs in
  MacUp, where the user saw the plan — not in a prompt nobody can see.
- **`--formula` and `--cask` are always explicit.** The same word can be a
  formula name and a cask token. MacUp does not let Homebrew pick which one
  the user reviewed.
- **Two guarantees have no flag at all.** `HOMEBREW_NO_INSTALL_CLEANUP` is
  the only way to stop `brew cleanup` running after an upgrade, and
  `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK` is the only way to stop Homebrew
  upgrading installed dependents of the named item — software the user never
  reviewed and may have excluded. Because they exist only in the
  environment, a plan's promises cannot live entirely in its argument array,
  which is why `UpdateProvider.executionEnvironment(context:)` exists and why
  the execution engine asks the provider for it instead of assembling one.

### Environment

- Read-only calls: the base allowlist plus `SSH_AUTH_SOCK` and any
  `HOMEBREW_*` variable the user has set, with `HOMEBREW_NO_AUTO_UPDATE=1`,
  `HOMEBREW_NO_ENV_HINTS=1`, and `HOMEBREW_NO_COLOR=1` forced.
  `HOMEBREW_NO_AUTO_UPDATE` matters because Homebrew's own
  `utils/auto-update.sh` lists `install`, `outdated`, `upgrade`, `bundle`,
  and `release` as commands that run `brew update` first; a normal check must
  not update Homebrew.
- Modifying calls: the same, plus `HOMEBREW_NO_INSTALL_CLEANUP=1` and
  `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1`.
- `PATH` for a child starts with the chosen `brew`'s own directory, so a tool
  that shells out to its siblings finds the installation MacUp chose.

### Planning and verification

- A pinned formula is refused rather than planned: MacUp does not unpin
  anything for you.
- A package ID whose namespace is neither `brew` nor `brew-cask` is refused,
  because MacUp will not choose between a formula and a cask on the user's
  behalf.
- A cask that installs through a macOS installer package carries "may require
  administrator authorization"; the plan says so, Homebrew and macOS do the
  asking, and MacUp neither supplies nor stores a password.
- Step timeout is one hour: a formula can build from source and a cask can be
  a multi-gigabyte download.
- Verification re-reads `brew info --json=v2 --installed` — already on the
  read-only allowlist, and it names no package, so verification cannot become
  a command that touches something else. The version it compares is the
  linked keg or installed cask version when Homebrew names one, otherwise the
  newest keg present: several versions can remain installed at once precisely
  because MacUp suppresses Homebrew's cleanup, so "installed" alone would not
  say which one the upgrade produced.
- Rollback: unavailable. No tested strategy.

### Read-only notes

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
- Never: a blanket `brew upgrade` with no item named, `brew cleanup`,
  `brew pin`, `brew unpin`.

## npm global packages (`npm`)

Capabilities: detect, inventory, outdated, planUpdates, verifyUpdates.
(No `refreshMetadata`: npm reads the registry each time.)

| Purpose | Command |
| --- | --- |
| Detect | `npm --version`, `node --version`, `npm prefix -g`, `npm root -g` |
| Candidates | `npm outdated -g --json` |
| Inventory | `npm ls -g --json --depth=0` |
| Update a package | `npm install -g <name>@<version>` |
| Verify | `npm ls -g --json --depth=0` |

### What `npm help install` changed

- **The version is named as part of the package spec.** `npm help install`
  documents `<name>@<version>` as resolved from the registry, and the version
  separated at the last `@`, which is what makes a scoped name such as
  `@anthropic-ai/claude-code` work. The bare `npm install -g <name>` form
  would install whatever `latest` points at when the command runs, which can
  differ from the version shown in the plan. Naming the version closes that
  gap and lets verification assert an exact result.
- **Anything in the version position that is not plainly a version is
  refused.** That position also accepts dist tags, ranges, paths, and git
  URLs, so `pkg@next` is a different request from the one the user approved.
  A published semantic version always starts with a digit; MacUp requires
  that, a length of at most 64, and a restricted character set, and refuses
  rather than interpreting anything else.
- The spec is one element of an argument array. Nothing is concatenated into
  a command line.

### Environment

- The base allowlist plus `NODE_EXTRA_CA_CERTS`, `PREFIX`, any
  `npm_config_*` variable, and any variable the user's `.npmrc` files
  reference as `${NAME}` — npm refuses to start when one of those is
  missing. Variables that would alter execution (`NODE_OPTIONS`, `DYLD_*`
  and similar) are excluded even when an npmrc names them.
- `npm_config_update_notifier`, `npm_config_fund`, and `npm_config_audit`
  are forced to `false`.
- `PATH` for a child starts with the owning Node's directory and the chosen
  `npm`'s own and canonical directories, so the package lands under the Node
  that owns the global tree.

### Planning and verification

- One package per command, so an exclusion cannot be bypassed.
- MacUp never uses `sudo`. If the global prefix is not the user's to write,
  npm fails and says so, and the plan says that will happen.
- The plan names the Node that owns the global packages and the tool
  managing it, because a global package belongs to one Node version:
  changing the active runtime later gives a different set of global packages.
- Updating `npm` itself is called out — it replaces the npm the shell and
  MacUp use, and updating Node through its manager may be the better route.
- Step timeout is 15 minutes.
- Verification re-reads `npm ls -g --json --depth=0`, which names no package.
  `npm ls` exits 1 when it finds problems but still prints the tree, so the
  parser decides the outcome, not the exit status.
- Rollback: unavailable. No tested strategy.

### Read-only notes

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

Capabilities: detect, inventory, outdated, planUpdates, verifyUpdates.

| Purpose | Command |
| --- | --- |
| Detect | `mise --version` |
| Candidates | `mise outdated --json` |
| Inventory | `mise ls --json` |
| Update a tool | `mise upgrade --cd <home directory> <tool>` |
| Verify | `mise ls --json` |

### What `mise upgrade --help` changed

- **`--bump` never appears, and the trust-invariants check now refuses the
  flag anywhere in the sources.** The help states the behaviour MacUp relies
  on: by default `mise upgrade` keeps the range specified in `mise.toml`, so
  `node@20` upgrades within 20.x. `--bump` is the flag that would rewrite the
  user's requested version, which CLAUDE.md §2.18 rules out doing
  automatically.
- **`--cd` is in the arguments, not left to the working directory.** mise
  walks up from the current directory to resolve configuration, so the same
  command run inside a project would target that project's configuration
  instead. Passing the directory explicitly means the command means the same
  thing wherever MacUp was started, and the reviewer can see which directory
  that is. Its value is the second positional argument, which is why the rule
  for this shape expects two.
- **Every mise plan says a lockfile may change.** The same help says the
  upgrade "will update mise.lock if it is enabled", and MacUp cannot see that
  setting from the outside. So `mayChangeUserConfiguration` is true for every
  mise plan rather than promising otherwise — which also means an `auto`
  mise item is escalated to Ask First by the policy engine's
  config-rewrite rule.

### Environment

- The base allowlist plus `GITHUB_TOKEN`, `GITHUB_API_TOKEN`, and any
  `MISE_*` variable. `PATH` for a child starts with the chosen `mise`'s
  directory.

### What mise refuses to plan

Four situations are refused with the reason rather than planned on a guess:

- **An exact pin** that still shows a newer version. The newest version
  matching the request is already installed; reaching the newer one means
  editing the request, which MacUp does not do for you.
- **A project's own configuration.** Reported, not changed — a global
  maintenance run must not rewrite a project's tool versions
  (CLAUDE.md §9).
- **A system-wide configuration** (`/etc/mise`).
- **A request MacUp could not attribute to a configuration file at all.**
  MacUp will not guess which file an upgrade would follow.

### Planning and verification

- Step timeout is one hour: mise compiles some runtimes from source.
- **The plan says the old runtime stays installed.** mise deletes unused
  versions only when someone runs `mise prune`, which is how you can tell
  `mise upgrade` does not delete them itself — and MacUp never prunes
  (CLAUDE.md §2.16, §9). That is worth stating for two reasons: it is disk
  the user may not expect to still be in use, and it is what makes going
  back to the old version easy, which matters more given that MacUp promises
  no rollback.
- A Node upgrade's plan states that global npm packages are installed per
  Node version, so the ones installed under the old version will not be
  there until they are reinstalled.
- Verification re-reads `mise ls --json` and compares the **active** version:
  mise keeps older installs around and MacUp does not prune them, so the
  active version is the one that answers the question.
- Rollback: unavailable. No tested strategy.

### Read-only notes

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
- Never: a blanket `mise upgrade` with no tool named, `mise install`,
  `mise prune`, `mise self-update`, `mise trust`, `mise use`, and never
  `--bump`.

## macOS (`macos`)

Capabilities: detect, outdated, refreshMetadata. **No `planUpdates`** — MacUp
reports macOS updates and does not apply them.

| Purpose | Command |
| --- | --- |
| Detect | none — the OS version and build come from `sysctl` |
| Candidates | `/usr/sbin/softwareupdate --list --no-scan` |
| Candidates with `--refresh` | `/usr/sbin/softwareupdate --list` (a fresh scan; the read-only guard treats it as a metadata refresh) |
| Update | none. `makePlan` refuses and says why. |
| Verify | nothing ran, so there is nothing to confirm (`notPerformed`). |

### Why macOS is still detection only

This is not an unfinished feature standing in for a plan that is nearly
ready. Applying a macOS update means downloading gigabytes, authorizing as an
administrator, and usually restarting the Mac. MacUp holds no password, hides
no authorization prompt, and restarts nothing (CLAUDE.md §2.9, §2.10, §2.19).

So the provider declares no `planUpdates` capability, the planner refuses by
capability rather than hoping `makePlan` throws, and `makePlan` itself throws
an error naming the reason and pointing at System Settings → General →
Software Update. Two separate refusals for the same fact, because either one
alone would be a single line of code between MacUp and a restart nobody
asked for.

The policy engine adds a third: every item whose provider is `macos` is
escalated to Ask First regardless of the configured policy. That rule checks
the *provider* rather than the OS-update risk signal, because
`softwareupdate` reports Safari and security updates without marking them as
OS updates.

Installation will need its own security review and its own tests before it
exists at all. Until then, MacUp reports macOS updates so a user has one
place to see them, and applies none of them.

Never `--install`, `--download`, `--background`, or anything requiring a
password.

### Read-only notes

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
