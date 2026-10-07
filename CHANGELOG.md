# Changelog

All notable changes to MacUp are recorded here, grouped as described in
`docs/RELEASE.md` (Added, Changed, Fixed, Security, Provider compatibility).
MacUp follows Semantic Versioning once releases begin.

0.1.1, 0.2.0, and 0.3.0 were never tagged on their own: everything in them
was first released in 0.4.0. Their sections keep the version
`docs/ROADMAP.md` assigned them, so each change stays with the work it
belonged to.

## [Unreleased]

### Added
- **Every package manager on this Mac**: `macup provider scan` and an "Also on
  This Mac" section on the app's Providers screen list the package managers
  and version managers MacUp finds — MacPorts, Nix, pipx, uv, pip, Poetry,
  conda, Cargo, rustup, RubyGems, Go, pnpm, Yarn, Bun, Deno, asdf, Volta,
  pyenv, rbenv, jenv, Composer, mas, and the shell-function ones, nvm and
  SDKMAN! — with the version of each and where it is installed. Reads only, in
  two ways: a copy in a location somebody else could write is reported and
  never run, and the only command the scan can issue is a tool's fixed version
  query, because its runner is the same read-only guard a check uses. Finding
  a tool is not managing it: MacUp still updates only Homebrew, npm, mise, and
  macOS, and proposes nothing for the rest.

- **Doctor can now fix what belongs to MacUp** (ADR-024): a rule naming
  software that is not installed, a configured provider path that cannot be
  used, and a scheduled run that is missing or should not be there each carry
  one change you can ask for — `macup doctor --fix <finding-id>`, or the
  button in the app. Both show exactly what will change first, ask, and go
  through the same approval gate as any other change; `--dry-run` changes
  nothing. A fix never runs a package manager, never touches a package, and
  never needs an administrator, and the fixer re-checks what the finding
  assumed immediately before acting. Everything else Doctor finds still
  explains and leaves the decision to you.

- **Scheduled updating, off by default** (ADR-023): `macup schedule enable
  --install-updates` and a switch on the app's Features screen let a scheduled
  run install the updates whose rule is Auto Update. It installs nothing else:
  an Ask First item is skipped with its reason rather than confirmed by a
  schedule, ignored and pinned items are never touched, and anything that may
  ask for an administrator password or need a restart is refused, because
  nobody is there to answer. A Mac that asks its owner to approve every change
  installs nothing on a schedule and says so, and a configuration MacUp cannot
  read fully stops the run before it starts. The launchd agent is still a
  per-user LaunchAgent with no root and no daemon, and it may now run exactly
  two commands — the read-only check, or `macup update --scheduled` — which
  `scripts/check-trust-invariants.sh` enforces.
- **What happened while you were away**: a scheduled run records every attempt
  and every skip in History, and the next time the app opens it says what the
  run did — in a notification, if you allow one. The `macup` command posts no
  notifications; it writes the history the app reads.

- **Leftovers of apps that are already gone**: `macup uninstall --orphans` and
  a "Left Behind by Apps You Removed" section on the app's Uninstall screen
  find the files in `~/Library` named after an app that is not installed any
  more — what dragging an app to the Trash leaves behind — grouped by the app
  that left them, biggest first, with their size. The rules are deliberately
  narrow: the name must be a bundle identifier of at least three parts outside
  Apple's namespace, no installed app may claim it, and the files must look
  like an app's rather than a tool's (a sandbox container or saved window
  state, or settings together with a data folder). MacUp cannot ask an app
  that is gone whether these are its files, so nothing is ticked for you:
  `macup uninstall leftovers:<bundle-id>` opens the ordinary review and you
  choose what goes.

| `macup uninstall --orphans [--json]` | Lists what apps you have already removed left in `~/Library`, biggest first, with why MacUp thinks an app left them. Reads only; nothing is ticked. `macup uninstall leftovers:<bundle-id>` reviews one. |
| `macup self-update [--dry-run] [-y] [--refresh] [--json]` |: `macup self-update` and a
  MacUp Updates section in the app's Settings. MacUp opens no connection of its
  own, so it never asks a server for a version: when Homebrew installed MacUp,
  Homebrew's own outdated list — the one every check already reads — is the
  answer, and updating is an ordinary Homebrew update with the same plan, the
  same exact command, the same confirmation, the same approval gate, and the
  same history as any other item. A copy you downloaded and moved into place is
  told where its releases are and left alone: MacUp never downloads, unpacks,
  or replaces itself. When Homebrew installed MacUp but could not be used,
  MacUp says it does not know rather than that it is up to date.

### Fixed
- **An uninstall now lists what an installer left in `/Library`.** An app
  whose installer names its helpers, daemons, and package receipts after the
  maker rather than after the app — `com.teamviewer.Helper` for
  `com.teamviewer.TeamViewer` — had none of them listed, so an uninstall could
  look complete while three launchd jobs, two privileged helpers, a
  `/Library/Application Support` folder, and seven receipts stayed behind.
  MacUp still removes none of it: each one is listed with the exact steps, and
  says which rule found it, because the maker's namespace and a folder named
  like the app are weaker signals than the bundle identifier. What another
  installed app's identifier or name claims is left to that app, and a shared
  maker is said so.
- **An app an installer put in `/Applications` as root** was described as
  belonging to another user. It now says an installer put it there as root.

## [0.4.0] — 2026-09-30

The first release that changes anything, and the first with downloads: a
universal `macup` command-line tool and a universal MacUp app, with SHA-256
checksums. The app is signed ad-hoc rather than with a Developer ID and is not
notarized, so macOS asks you to approve it once (see the README).

### Added
- **Uninstall apps and packages with nothing left behind**: a new Uninstall
  screen (after Updates) and `macup uninstall`, for apps like ChatGPT or a
  game, Homebrew formulae and casks, npm global packages, and mise runtimes
  such as Python or Node — through the package manager's own uninstall, then
  the files it left in `~/Library`. Each uninstall starts with a review: a
  Move to Trash / Delete Permanently switch at the top (Trash every time),
  what the package manager will run, every file with its size, what clearly
  belongs to it ticked and your data (chats, saved games, databases) not,
  Select Everything for no residue, and what only you can remove with the
  steps. An open app, a formula others need, and anything needing an
  administrator are never touched. `macup self-uninstall` and Settings >
  Uninstall MacUp remove MacUp itself. Every uninstall is in History.
- **History that says what happened**: one plain headline per attempt
  ("Stopped before the update finished", "Updated and confirmed"), labelled
  facts ("via Homebrew · started from the MacUp app · ran for 1 minute, 35
  seconds"), and before → target → after versions. After an attempt that
  did not succeed, MacUp reads the item back (reading only) and records what
  it found. `macup history <package-id>` and `--search`; a search field and
  per-item view in the app, and Recent Attempts beside each update.
- **Skip This Version** and item notes: `macup policy skip|unskip|note`, and
  the same in the app's rule menu, detail pane, and dashboard. A skipped
  version stays out of plans until a different one is offered; when MacUp
  cannot tell which version is on offer, it leaves the item alone.
- **`macup explain <package-id>`**: everything MacUp knows about one item —
  versions, what changes, risk and every reason, notes, the rule that
  decided, the exact command or why there is none, and its history. The app's
  Copy Details copies the same text, and Copy Command copies the command.
  The menu bar lists pending updates, each opening its item.
- **Search, filter, and sort** on the Updates screen (by provider, risk,
  policy in effect, and Needs Attention), always saying how many updates a
  filter hides; `--risk`, `--policy`, `--attention`, and `--sort` on
  `macup check` and `macup plan`. ⌘1–⌘6 switch sections and ⌘F searches.
- **What an update affects**: formulae running as `brew services` say so,
  and a database moving to a new major version is high risk and always asks
  first, with a note to back up, because its first start may convert its
  data. `macup dependents <package-id>` and Show What Depends on It answer
  `brew uses --installed`, on request only.
- **Doctor checks for Homebrew's own state**: an install that did not finish,
  a formula with no linked version, and a prefix that makes Homebrew compile
  from source, each with safe manual repair steps in the right order.
- **Export Diagnostics**: `macup diagnostics preview|export` and Settings >
  Diagnostics write one redacted JSON file for a bug report — package names
  replaced by placeholders unless asked for, secrets, home paths, and the user
  name removed, no environment variables, never overwriting, readable only by
  you.
- **App layout**: the sidebar is now Dashboard, Providers, Updates,
  Features, Doctor, History. The dashboard lists pending updates first and
  the items your rules ignore or hold below them, each with the way to clear
  its rule.
- **Providers screen**: every provider MacUp knows, what was found and where,
  a switch to turn it on or off, and the rule its items inherit.
- **What changes**: each update shows which parts of the version change
  (major, minor, patch, build, pre-release, packaging revision), and a link
  to read about the release where the provider gives one — npm's page for
  that version, or the Homebrew homepage. MacUp only builds the address and
  accepts `https` only; it fetches nothing. In the app's Updates screen and
  in `macup check --verbose`.
- **Doctor**: eleven deterministic diagnostics that read the result of one
  read-only check and say what they saw. Provider availability and results;
  multiple Homebrew installations and a non-standard prefix; executable
  architecture; the login shell's `PATH` against MacUp's own; runtime
  ownership; which Node owns the global npm packages; configuration problems
  and item policies that no longer name installed software; whether MacUp's
  own directories are usable and private; and whether a configured schedule
  is really installed and loaded. Available in both surfaces.
- Findings carry stable, namespaced identifiers (`homebrew.multipleInstallations`,
  `paths.directoryWritableByOthers`) because scripts will match on them, and
  are ordered deterministically — most severe first, then by identifier, then
  title, then detail — so two runs over one machine agree.
- Binary architecture is read from the Mach-O header directly rather than
  through `lipo` or `file`: Doctor does not depend on another tool being
  present or on parsing its prose, and only the header is read, never the
  megabytes behind it. A header MacUp cannot interpret — a script, a Java
  class file that shares the universal magic, an unknown CPU type — is
  reported as undetermined and produces no finding.
- The runtime ownership checks exist because "which version is active" has
  two true answers on a real developer's Mac: mise can report node 24 active
  while an earlier `PATH` entry runs node 22, and the global npm packages
  belong to whichever Node runs npm. Doctor reports both installations, which
  one wins, and where the global packages actually live.

### Fixed
- **Face enrolment never had a camera to capture from**: its session was
  built with the bare `init()`, which adds no camera input. It can now only
  be built from a camera device. `scripts/build-app.sh` signs with an Apple
  Development or Developer ID certificate when one is installed, which macOS
  needs before it asks for camera access.
- **Stop no longer breaks what it stops.** Pressing Stop in the app (or
  Escape, which was bound to it), or Ctrl+C in the CLI, sent the running
  package manager SIGTERM and then SIGKILL three seconds later. During a
  `brew upgrade` that could kill Homebrew between unlinking the old version
  and linking the new one, which is what happened to a `mysql` upgrade:
  an empty folder for the new version and neither version linked. A command
  that changes something is now never killed; Stop means "after this item",
  and on its time limit such a command is interrupted the way Ctrl+C would,
  then waited for. Escape no longer triggers Stop.
- **An unfinished Homebrew install is recognized.** A version folder with no
  `INSTALL_RECEIPT.json` is reported as an install that did not finish, the
  version shown is the one in use (the linked keg or `opt` link), and MacUp
  refuses to plan another upgrade on top of it. Verification no longer takes
  an empty folder named after the target as a successful upgrade.
- **A build from source is said up front.** When Homebrew has no ready-made
  build for where it is installed (any prefix other than the one a bottle was
  made for), the update, its plan, and the running sheet say it will be
  compiled and can take an hour or more; its time limit is four hours.
- **The running sheet explains itself**: how long the command has been
  running, its latest output lines, and a progress bar that no longer reads
  as finished while the only item is still running. `macup update` prints the
  package manager's output as it arrives.
- The update list no longer shows "Changes: The two versions are the same."

- The app now offers Pin for every item, as `macup policy set <id> pin`
  always has. It used to hide Pin behind a provider capability no provider
  declares, and said Homebrew had no pin of its own. Both surfaces now say
  that Pin is MacUp's own hold and does not pin the item in its package
  manager.
- The Doctor and History toolbar buttons no longer share the Check Now icon.

### Security
- Doctor issues exactly one command — reading the user's login shell — through
  the same `CommandRunning` abstraction as everything else, with effect
  `readOnly`. The captured environment is compared and dropped rather than
  logged. Everything else is read from bytes or from `stat`.
- Everything that reaches a finding is redacted and sanitized first: the home
  directory becomes `~` so a pasted report carries no username, and no finding
  prints an environment variable's value. A test plants `GITHUB_TOKEN`,
  `AWS_SECRET_ACCESS_KEY`, and `NODE_OPTIONS` and asserts that none of their
  values appear.
- Doctor explains. It has no fix action, not even an opt-in one.
- The uninstaller no longer takes an app's bundle identifier at its word. One
  with fewer than three parts (`com`, `com.google`) finds no files, and one in
  Apple's namespace finds files but ticks none of them, so an app claiming
  `com.apple` cannot sweep macOS's own settings.
- A cask's `zap` wildcard must be tied to the app. A pattern such as
  `~/Library/Preferences/*` is listed as left in place instead of expanded,
  and entries named in Apple's namespace are never ticked.
- A folder a cask removes only when empty is removed only if it is empty when
  MacUp reaches it; one holding other files is never offered, not even by
  Select Everything.
- A folder with another disk mounted inside it is never removed, and a folder
  deleted permanently is checked again for one first.
- Export Diagnostics also masks the names and bundle identifiers of apps
  MacUp uninstalled, which skip reasons and errors can mention.

## [0.3.0] — released in 0.4.0

Controlled updates: MacUp can change the machine, one named item at a time,
from a plan the user read first.

### Added
- Per-item updates for Homebrew formulae and casks, npm global packages, and
  mise-managed runtimes, through `macup update` and the app's Updates screen.
  `macup update --dry-run` describes everything and runs nothing.
- Verification by the owning provider after every successful update, using
  read-only commands that name no package. A version that did not move is
  reported as not reached and output MacUp could not parse as failed; neither
  is rounded up to success.
- Update history at `~/.local/state/macup/history.jsonl`, one JSON object per
  line: when, where the run came from, the item, the versions before, targeted
  and observed, the exact commands as displayed, the outcome, the verification
  outcome, an error summary, and the duration. Read it with `macup history`
  and on the app's History screen.
- Every skip is recorded with its reason. An item MacUp decided not to change
  is part of what it did, and the reason is the useful half.
- Cancellation reaches the running command rather than leaving it to finish
  unwatched.
- Providers answer for the environment their own commands need
  (`UpdateProvider.executionEnvironment`). A plan carries the exact executable
  and arguments — that is what a person reviews — but two of a Homebrew plan's
  promises have no command-line flag and live only in the environment.

### Security
- `ExecutionGuard` wraps the command runner for the length of one plan and
  compares every invocation against that plan's own steps and verification
  commands, by executable, argument array, and effect. A change must match a
  reviewed `ModifyingCommandRule` as well, so being listed in a plan is not by
  itself permission to run a shape of command nobody vetted. Anything else is
  refused before it reaches the operating system, and the refusal names the
  command. "MacUp only runs what it showed you" is now a property of the code.
- `ModifyingCommandRules` lists the four shapes MacUp may ever run, in one
  reviewable place. Positional arguments are allowed — a modifying command
  names the thing it changes — and then checked rather than trusted: no
  leading `-`, no control or bidirectional-override characters, and an
  **exact** count, because naming too few is the dangerous case. `npm install
  -g` with no package installs the working directory as a global package, and
  `brew upgrade` with no formula upgrades everything, walking past every
  exclusion.
- The configuration file is re-read and policy re-asked immediately before
  each item. The copy planning used may be minutes old, and the rule the user
  changed in between is the one that should win.
- A decision needing confirmation runs only for an item the caller confirmed,
  and only when somebody was there to confirm it. A scheduled run therefore
  touches nothing but Auto Update items, and skips anything that might ask for
  a password or a restart.
- Items run strictly one at a time. Two package managers rewriting the same
  machine at once is not something MacUp could reason about afterwards, let
  alone explain.
- A failed step ends that item, and a failure ends the run's appetite for
  high-risk and unjudged changes: after a failure MacUp no longer knows the
  state of the machine as well as it did when the plan was written.
- `HOMEBREW_NO_INSTALL_CLEANUP` and `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK`
  are set for every Homebrew upgrade. Neither has a command-line flag, and
  without them an upgrade cleans up afterwards — which MacUp never does on its
  own — and upgrades installed dependents, which are packages the user never
  reviewed and may have excluded.
- Verification is given no modifying rules at all, and only the read-only
  rules — not the metadata-refresh one. `brew update` is on the check
  allowlist for `macup check --refresh`, and an update the user reviewed never
  said it would refresh anything.
- Detection runs once per provider per run, through a runner that allows
  nothing but the read-only allowlist, and its result is reused for
  verification, so the version MacUp reads back comes from the installation it
  just changed. A provider MacUp cannot find, or does not have loaded, means
  the plan does not run.
- Steps run with the home directory as the working directory, never the
  directory MacUp happened to be started in, so a tool that reads
  project-local configuration cannot pick up whichever project the shell was
  sitting in.
- History is held to the configuration file's rules: owner-only, never written
  through a symlink, never into a directory somebody else could change, one
  redacted JSON object per line, trimmed by atomic replace so a crash during a
  trim cannot lose the entries it was keeping. A line it cannot decode is
  skipped and reported rather than guessed at. Entries are redacted by the
  engine and again by the store, so a caller that forgets cannot put a secret
  in the audit log. A dry run records nothing, because it attempted nothing.
- `scripts/check-trust-invariants.sh` previously banned modifying provider
  verbs everywhere. It now permits them only in the one rules file and the one
  planning file per provider, and still fails for the CLI, the app, discovery,
  and scheduling. `--bump` may appear nowhere at all.

### Provider compatibility
- Command shapes were confirmed against each tool's own help — `brew help
  upgrade`, `mise upgrade --help`, `npm help install` — rather than from
  memory, and reading that help changed real decisions, which
  `docs/PROVIDER_NOTES.md` records next to each command.
- Homebrew: `brew upgrade --formula --yes <name>` and `brew upgrade --cask
  --yes <token>`. `--yes` because Homebrew's ask mode is now the default and
  MacUp's subprocesses have no terminal to answer from; the confirmation
  belongs in MacUp, where the user saw the plan. `--formula` and `--cask` are
  always explicit, because one word can be both and MacUp does not let
  Homebrew pick which one the user reviewed.
- mise: `mise upgrade --cd <home> <tool>`. `--bump` never appears, so the
  requested range is preserved and no major version is bumped. `--cd` pins the
  directory mise resolves configuration from, so the command means the same
  thing wherever MacUp was started and the reviewer can see which directory
  that is. Every mise plan says a lockfile may change, because mise updates
  `mise.lock` when lockfiles are enabled and MacUp cannot see that setting
  from the outside. Every mise plan also says the version you have now stays
  installed: mise removes unused versions only when asked, and MacUp never
  asks — which is also what makes going back easy, given that MacUp promises
  no rollback.
- npm: `npm install -g <name>@<version>`, with the version named as part of
  the package spec so the plan and the install agree. Anything in that
  position that is not plainly a published version is refused, because
  `pkg@next` is a different request from the one the user approved.
- macOS refuses to plan and says why. That is not an unfinished feature:
  applying an OS update needs an administrator and usually a restart, and
  MacUp holds no password and restarts nothing.

## [0.2.0] — released in 0.4.0

### Added
- **Policy**: Auto Update, Ask First, Ignore, Pin, and Inherit, resolved per
  item, then per provider, then from the global default. `macup policy list`,
  `macup policy set <package-id> <policy>`, `macup policy clear <package-id>`,
  `macup provider enable|disable <provider>`, and the same controls in the
  app. Every decision carries a human-readable reason naming the item, so a
  plan that lists twenty skips says which item each line is about.
- **Planning**: `macup plan` and `macup update --dry-run` produce every change
  MacUp would make, with the exact executable and argument array, alongside
  every change it would not and why. A plan runs nothing to produce itself:
  the planner reuses the installation the read-only check already chose and
  hands providers a runner wrapped in the read-only guard, so a provider that
  tried to run something while describing a plan would be refused.
- A plan states whether network is expected, whether privilege may be
  required, whether a restart may be required, whether user configuration may
  change, how it will be verified, and whether it can be rolled back.
- `PolicyEditor` is the single door for changing a rule, so the CLI and the
  app's controls cannot drift apart.
- `PolicyListing` answers "what are my rules?" and resolves inheritance
  through the policy engine, so a listing can never disagree with the decision
  the user will actually get. Item keys it could not parse are reported rather
  than quietly dropped.

### Changed
- `auto` no longer means "decide anything the risk model rates below high".
  macOS updates, runtime major changes, and unknown risk are always Ask First;
  MacUp never walks into an administrator prompt or a restart on its own, and
  it does not edit a config file or lockfile unasked. Those rules hold
  regardless of `confirmMajorUpdates`, which now governs only the case it was
  written for — an ordinary package's major version bump.
- The macOS rule checks the provider rather than the OS-update signal, because
  `softwareupdate` reports Safari and security updates without marking them as
  OS updates.

### Security
- A configuration MacUp could not read allows nothing, because the rules
  saying which items are excluded are exactly the ones it could not read.
- A provider turned off in the configuration allows nothing, and an item the
  provider itself pins allows nothing — MacUp never unpins something you
  pinned in Homebrew.
- Every provider plan names the single item it would change. `brew upgrade`
  and `mise upgrade` with no arguments touch everything the tool considers
  outdated, which would walk straight past the items a user excluded, so
  naming the item is what makes an exclusion mean anything.
- A candidate policy refused becomes a recorded skip and never reaches the
  planned list, so an ignored or pinned item cannot end up in something a bulk
  action would run. A candidate whose provider cannot produce a plan becomes a
  skip carrying the provider's error, never a guess.
- A provider MacUp has no plan for is refused by capability rather than by
  hoping its planning method throws.
- `PolicyEditor` refuses more than it accepts: a package ID is validated
  before anything is written; a configuration with errors is never rewritten,
  because MacUp saves the file by re-encoding what it understood and
  rewriting a file it misread could drop the exclusions the user is relying
  on; and an edit validates its own result, so `pin` cannot land on a whole
  provider. That refusal is also what keeps keys MacUp does not know — an
  unrecognized key is already a configuration error, so the file is left
  exactly as the user wrote it.
- No plan claims rollback, because none has a tested strategy.

## [0.1.1] — released in 0.4.0

Scheduled read-only checks, and optional approval before a change. A
scheduled *check* needs neither the policy engine nor the execution engine,
so it did not have to wait for them.

### Added
- Optional approval before MacUp changes anything: `macup security require on`
  and `macup security status [--json]`, with the same switch in the app under
  **Settings → Approval**. macOS asks through `LocalAuthentication` using
  whatever sensor the Mac reports — Touch ID, Face ID, or Optic ID — with the
  login password or an unlocked Apple Watch as the fallback. MacUp never sees
  a fingerprint, a face, or a password. One `ApprovalGate` serves the CLI and
  the app, so the execution engine cannot skip it later. Approval that could
  not be obtained is a refusal (exit status 77), never a pass. Documented as a
  confirmation, not a lock: MacUp runs as you, and so do brew, npm, and mise.
- A camera face match of MacUp's own, off by default: `macup security face
  enroll|status|forget`, and Enroll/Forget in the app under Settings →
  Approval. No Mac has a Face ID sensor and macOS exposes no face-recognition
  API, so this crops to the face and compares Vision image feature prints —
  how alike two pictures look. A photograph of the enrolled person passes it,
  which the CLI, the app, the README, and `docs/TRUST_AND_SECURITY.md` all say
  plainly. It can only approve early: a face that does not match falls through
  to the macOS prompt, so it can never lock anyone out, and it reports
  `cameraFace` rather than `faceID` so it is never mistaken for a sensor.
  Enrolment stores numbers, not images, owner-only, and reports how far apart
  your own samples are so the threshold can be judged.
- Scheduled read-only checks: `macup schedule enable`, `macup schedule
  disable`, and `macup schedule status [--json]`. Enabling installs a launchd
  **user agent** (`com.macup.check`) that runs `macup check --save-state` at
  the chosen time. It runs as you, needs no administrator authorization,
  leaves no process running between checks, and `disable` removes it
  completely. The scheduled job can only ever run a read-only check, which a
  static invariant enforces; scheduled *updating* is still not implemented
  (see `docs/ROADMAP.md`, v0.6.0).
- A **Features** screen in the app's navigation: one row per feature, one
  switch each, in plain language — automatic checks, approval, and face match.
  The switches moved there from Settings, which goes back to being the
  configuration inspector: where the file is, what is in it, and what MacUp
  read from the environment.
- Settings is reachable from the app itself: a row at the bottom of the
  sidebar and a toolbar button, not only ⌘, and the menu bar.
- The app schedules checks too: **Settings → Scheduling** has the switch,
  frequency, day, time, and metadata-refresh controls, shows the exact command
  it will install before turning it on, and reports what is really scheduled
  rather than what the configuration asks for. The Dashboard and the menu bar
  show the next check when one is actually loaded.
- `MacUp.app` now bundles the `macup` CLI at `Contents/Helpers/macup` and
  schedules that copy, so a scheduled check can never be a different version
  of MacUp than the app that scheduled it.
- `macup check --save-state` writes the report to
  `~/.local/state/macup/last-check.json`, which `macup schedule status`
  summarises.
- `schedule.refresh` (default `true`) controls whether a scheduled check
  refreshes package metadata first. Without it `brew outdated` reads local
  metadata that may be weeks old, so a nightly check would report almost
  nothing; a refresh updates package lists only.
- `MACUP_LAUNCH_AGENTS_DIR` overrides the LaunchAgents directory, for testing.
- Homebrew tap: `brew install sd2389/macup/macup` builds MacUp from the
  tagged source.

### Fixed
- `macup config show` no longer presents the `schedule` section as if it
  worked while nothing read it. Before scheduling existed, turning it on in
  the file was accepted, validated, and echoed back, and then nothing ran.
- CI and the development guide find the built `macup` through SwiftPM
  (`swift build --show-bin-path`, `swift run`) instead of assuming
  `.build/debug`, which newer toolchains no longer use.

## [0.1.0] - 2026-09-26

Read-only alpha: MacUp reports what is outdated and never changes anything.

### Added
- Project documentation materialized from `MACUP_MASTER_BUILD_SPEC.md`.
- Apache-2.0 license.
- Swift package with the `MacUpCore` library, the `macup` CLI, and Swift
  Testing test targets.
- `ProcessCommandRunner`: argument arrays only, allowlisted environment,
  `/dev/null` stdin, bounded stdout/stderr capture, streaming, timeouts with
  SIGTERM→SIGKILL escalation, and task cancellation.
- Intentional executable resolution (configured path → search path → standard
  locations) that ignores relative `PATH` entries and never falls back from an
  invalid configured path.
- `ReadOnlyCommandGuard` and command recording for read-only operations.
- Secret redaction and terminal-safe rendering of untrusted text.
- `macup config path` and canonical config/state locations.
- CI workflow and `scripts/check-trust-invariants.sh`.
- Domain models, SemVer-agnostic version comparison, and a coarse risk model.
- Versioned configuration (schema 1) with strict, fail-closed validation,
  atomic owner-only writes, and backup-before-migration.
- Read-only providers: Homebrew formulae and casks, npm global packages,
  mise runtimes and tools, and macOS software update detection.
- Concurrent `macup check` (default command) with `--json`, `--refresh`,
  `--provider`, `--inventory`, and `--verbose`; `macup provider list`;
  `macup config show`.
- Read-only command allowlist enforced for every check.
- Read-only SwiftUI desktop app: Dashboard, Updates, Doctor, History,
  Settings window, and a menu bar extra, built with `scripts/build-app.sh`.
- Login-shell environment discovery so the app finds the same tools as the
  terminal.
- `make install` / `make uninstall` for the CLI; `macup providers` and
  `macup config` shortcuts; examples in `macup --help`; risk levels colored
  on terminals.

### Security
- Security policy with private vulnerability reporting, and the Contributor
  Covenant 2.1 as the Code of Conduct.
- Dependabot updates for GitHub Actions and Swift packages.
- Provider output is treated as untrusted: names with control characters,
  bidirectional overrides, or leading dashes are skipped; human output is
  sanitized for the terminal, and JSON output escapes the same characters;
  errors are redacted.
- Hardening from a pre-release security audit:
  - A configuration file (or its directory, or a symlinked file's target
    directory) that other users could change is ignored entirely, so it cannot
    choose which executables MacUp runs. The ownership checks and the read now
    use one open file.
  - A configured `executablePath` is checked exactly as written; empty or
    padded values fail instead of falling back to `PATH`.
  - Standard install locations (`/opt/homebrew/bin`, `/usr/local/bin`) are used
    only when root or the user controls the file and every directory above it.
  - Redaction covers more credential shapes (multi-word and unterminated
    values, `KEY`/`PASS`/`DSN` names, JSON keys, token-only URL userinfo,
    Stripe and Google keys).
  - Checks that failed, were cancelled, skipped unreadable updates, or got
    incomplete results from mise are reported as incomplete (exit status 2 in
    the CLI; a warning instead of a checkmark in the app), never as "up to date".
  - Truncated provider output is an error; npmrc files can no longer forward
    `NODE_OPTIONS`, `DYLD_*`, or similar variables; the fresh `softwareupdate`
    scan is guarded as a metadata refresh; MacUp refuses to run as root.
  - Builds use the dependency revisions pinned in `Package.resolved`
    (`--force-resolved-versions`), and CI fails if they change.
  - `make app` builds a release app; the debug-only snapshot mode writes only
    into a private directory.

### Provider compatibility
- Verified against Homebrew 7.0.6, npm 10.9.8/11.17.0, mise 2026.7.3, and
  `softwareupdate` on macOS 27.0; parsers accept older output shapes.

[0.4.0]: https://github.com/sd2389/macup/compare/v0.1.0...HEAD
[0.3.0]: https://github.com/sd2389/macup/compare/v0.1.0...HEAD
[0.2.0]: https://github.com/sd2389/macup/compare/v0.1.0...HEAD
[0.1.1]: https://github.com/sd2389/macup/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/sd2389/macup/releases/tag/v0.1.0
