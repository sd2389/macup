# CLI reference

## What can change your machine

Exactly one command installs or upgrades anything: **`macup update`**. It
shows the plan first, asks about anything your policy marks Ask First, runs
one item at a time, verifies each result, and records what happened. It never
cleans, prunes, removes, or uninstalls, and it never upgrades an item it did
not name.

These commands write **MacUp's own configuration file** and no packages:
`macup policy set`, `macup policy clear`, `macup policy skip|unskip|note`,
`macup exclude`, `macup provider enable`, `macup provider disable`, `macup
schedule enable`, `macup schedule disable`, `macup security require`, and
`macup security face enroll|forget`.

**Everything else only reads**, including plain `macup`, `macup check`,
`macup plan`, `macup explain`, `macup doctor`, `macup history`, `macup policy list`,
`macup provider list`, and `macup config`.

Nothing runs on a schedule but a check. The launchd agent MacUp installs is
only ever allowed to run `macup check --save-state`, and a static check in
CI enforces that.

## Install

```bash
brew install sd2389/macup/macup  # builds from source; brew uninstall macup removes it
```

Or from a clone:

```bash
git clone https://github.com/sd2389/macup.git
cd macup
make install                    # into ~/.local/bin
make install PREFIX=/usr/local  # or anywhere else (may need sudo)
make uninstall                  # remove it
```

Building needs macOS 14+ and the Xcode Command Line Tools
(`xcode-select --install`). `make install` tells you if the install folder is
not on your `PATH` yet.

### Shell completions

The Homebrew formula installs bash, zsh, and fish completions. For a clone
install:

```bash
mkdir -p ~/.zsh/completions
macup --generate-completion-script zsh > ~/.zsh/completions/_macup
# then, in ~/.zshrc before compinit:  fpath=(~/.zsh/completions $fpath)
```

`bash` and `fish` work the same way (`--generate-completion-script bash|fish`).

## Commands

| Command | What it does |
| --- | --- |
| `macup` | Same as `macup check`. |
| `macup check` | Detects providers and lists available updates. |
| `macup check --refresh` | Refreshes provider metadata first (see below), then checks. |
| `macup check --json` | Machine-readable report (schema version 1). |
| `macup check --provider <id>` | Checks only `homebrew`, `npm`, `mise`, or `macos`. Repeatable. |
| `macup check --inventory` | Also lists installed items. |
| `macup check --verbose` | Adds what changes between the two versions, a link to read about the release where the provider gives one, ownership chains, risk reasons, notes, and every command MacUp ran. |
| `macup check --save-state` | Also writes the report to `~/.local/state/macup/last-check.json`. This is how a scheduled check leaves its result behind. |
| `macup check --risk <level>… --policy <policy>… --attention --sort <order>` | Narrows and orders the list: by risk (`low`, `moderate`, `high`, `unknown`), by the policy in effect (`auto`, `ask`, `ignore`, `pin`), to the updates that need attention (an earlier install that did not finish, or a build from source), and sorted by `provider` (the default), `risk` (highest first), `name`, or `change` (largest version change first). `--risk` and `--policy` repeat; values within one option are alternatives and the options combine. What is checked, the counts, and the exit status do not change, and the output says how many updates the filter left out. |
| `macup plan [<package-id>…] [--refresh] [--json] [--verbose]` | Shows what `macup update` would do: current → proposed version, provider, effective policy, risk and its reason, and the exact executable and arguments — plus every item it would leave alone, with the reason. Launches nothing. Takes the same `--risk`, `--policy`, `--attention`, and `--sort` as `check`. |
| `macup explain <package-id> [--refresh] [--json]` | Everything MacUp knows about one item: installed and available versions, what changes and the release link, risk and every reason, notes, who manages it, the policy that decides it and the rule behind that, the exact command it would run — or exactly why it would run nothing — and its recent history. Launches nothing. The app's Copy Details copies the same text. |
| **`macup update [<package-id>…]`** | **The only command that changes packages.** Flags below. |
| `macup doctor [--json] [--verbose]` | Runs MacUp's deterministic diagnostics and explains each finding. Fixes nothing. |
| `macup history [<package-id>…] [--search <text>] [--limit N] [--json] [--verbose]` | What MacUp has changed and what it decided not to change, newest first, each opening with one line that says what happened. Name package IDs to see only those items; `--search` keeps the entries whose item, provider, or outcome contains every word. See below. |
| `macup policy` / `macup policy list [--json]` | Every policy rule, the global default, and where each lives in the file. Read-only. |
| `macup policy set <target> <auto\|ask\|ignore\|pin\|inherit> [--json]` | Sets the rule for a package ID, a provider name, or `default`. |
| `macup policy clear <target>… [--json]` | Removes an item's rule, or sets a provider back to `inherit`. |
| `macup policy skip <package-id> [--version <v>] [--json]` | Leaves one version out of plans until a different one is offered. Without `--version`, a read-only check of the item's provider finds the version on offer; nothing on offer is exit 64, a provider that could not be checked exit 2. See docs/CONFIGURATION.md. |
| `macup policy unskip <package-id>… [--json]` | Stops skipping, so that version follows the item's rule again. |
| `macup policy note <package-id> "<text>"` / `--clear` `[--json]` | Keeps your own one-line note on an item (at most 200 characters), shown in `policy list`, `check`, `plan`, and the app, and never acted on. |
| `macup exclude <package-id>… [--json]` | Shorthand for `macup policy set … ignore`; the same rule in the same place. |
| `macup providers` / `macup provider list [--json]` | Shows which providers were found and exactly which installation MacUp uses. Runs detection only. |
| `macup provider enable <id> [--json]` | Lets MacUp check a provider again and propose its updates. |
| `macup provider disable <id> [--json]` | Stops MacUp checking a provider. Uninstalls nothing. |
| `macup config` / `macup config show [--json]` | Shows the configuration in effect and every problem with it. Never creates the file. |
| `macup config path [--json]` | Prints the configuration file and state directory locations. |
| `macup schedule` / `macup schedule status [--json]` | Shows whether a check is scheduled, when it next runs, and what the last one found. Read-only. |
| `macup schedule enable [--frequency daily\|weekly] [--time HH:mm] [--weekday <day>] [--no-refresh]` | Installs the launchd user agent that runs a read-only check, and records it in the configuration. |
| `macup schedule disable` | Removes the agent and clears the setting. |
| `macup security` / `macup security status [--json]` | Shows which sensor this Mac has and whether MacUp asks for approval. Read-only, no prompt. |
| `macup security require <on\|off> [--no-password-fallback]` | Turns the approval requirement on or off. |
| `macup security face` / `macup security face status [--json]` | Whether a face is enrolled, and how well it can match. Opens no camera. |
| `macup security face enroll [--samples <n>]` | Takes a few pictures and remembers what they look like. |
| `macup security face forget` | Deletes the enrolled face and turns the camera check off. |
| `macup --help`, `macup --version` | Help and version. |

### `macup update`

| Flag | What it does |
| --- | --- |
| *(no arguments)* | Considers every update your policy allows. |
| `<package-id>…` | Only these items. An ID that is not a package ID, or that has no update available, is an error and nothing runs. Naming an item is a request, not a confirmation. |
| `--dry-run` | Shows the plan and launches nothing. Nothing is recorded in history. |
| `-y`, `--yes` | Confirms every item in the plan MacUp just showed. |
| `--refresh` | Refreshes provider metadata before planning. Changes no package. |
| `--stop-on-failure` | Stops at the first failure instead of moving on. |
| `--json` | Prints an `ExecutionReport` (schema version 1). Never asks anything. |
| `-v`, `--verbose` | Shows every command with its exit status and timing. |

### Worked examples

```bash
macup                                  # what is outdated
macup check --refresh --json           # fresh metadata, machine-readable
macup plan                             # the exact commands an update would run
macup plan brew:git --verbose          # one item, with rollback and verification
macup explain brew:git                 # everything about one item, and its history
macup check --risk high --sort change  # the riskiest updates, biggest jumps first
macup plan --policy ask                # only what will wait for your confirmation
macup update --dry-run                 # the same, launching nothing
macup update                           # apply what policy allows, asking about the rest
macup update brew:git npm:prettier -y  # two named items, confirmed up front
macup policy list                      # every rule and where it lives
macup policy set brew:postgresql ignore
macup policy set homebrew auto         # a whole provider
macup policy set default ask           # the fallback for everything else
macup policy clear brew:postgresql
macup policy skip brew:mysql           # not this version; the next one is offered as usual
macup policy note brew:php "waiting for PHP 8.4 support"
macup exclude npm:@anthropic-ai/claude-code
macup provider disable mise
macup provider enable mise
macup doctor                           # what is odd about this Mac
macup doctor --json                    # the same, machine-readable
macup history --limit 50               # what MacUp has done
macup history brew:mysql               # every attempt at one item, and what each left
macup history --search stopped         # the runs that were stopped
```

### What `macup history` says

Each entry opens with one headline chosen from what happened to the attempt
and what MacUp found when it read the item back — for example "Upgraded and
confirmed", "Updated, but MacUp could not confirm the new version", "Failed
— git was not updated", or "Stopped before the update finished". Under it:
the version before, the one the plan aimed for, and, when MacUp read it back,
the one in use afterwards (`9.7.1 → 26.7.0_2 · now 9.7.1`); anything else the
read-back showed, such as a formula left unlinked; and the labelled facts
(`via Homebrew · started from the MacUp app · ran for 1 minute, 35 seconds`).
The provider's own error text follows as `Details:`, never as a second
verdict. `--verbose` adds the commands MacUp ran.

MacUp reads an item back after a success, to confirm it, and also after an
attempt that started a command and failed, timed out, or was stopped, because
a package manager stopped part-way can leave the item changed. An entry
written before MacUp did that has no after-state, and says nothing about one
rather than guess. `macup history <package-id>` with a limit counts that
item's entries, however many others were written since.

## How `macup update` decides to run something

Five things have to line up, and every one of them can only ever stop a
change:

1. **Policy.** The item's own rule wins over its provider's rule, which wins
   over the default. `ignore` and `pin` never run. A provider that is off
   never runs. A formula Homebrew itself has pinned never runs, and MacUp
   does not unpin it for you. A version you skipped never runs, even named
   and confirmed; a different version follows the rule as usual.
2. **Risk.** An item set to `auto` still waits for you when the change is a
   macOS update, a major runtime change, unknown risk, or would need an
   administrator password, a restart, or a rewrite of your configuration or
   a lockfile. `confirmMajorUpdates` governs only an ordinary package's major
   version bump; it cannot buy past the rules above it.
3. **Your confirmation**, for anything left at "needs your confirmation":
   - With `--yes`, every item in the plan MacUp just printed is confirmed.
   - Otherwise, **when stdout is a terminal** MacUp prints the plan and asks
     once: `Run the 2 changes that need your confirmation, shown above? [y/N]`.
     Only `y` or `yes` is a yes; no answer, a closed input, or anything else
     is a no.
   - **When stdout is not a terminal** — a pipe, a script, a log — MacUp asks
     nobody. It lists those items, leaves them alone, and says how to confirm
     them. This is why a scripted `macup update` can never silently change an
     Ask First item.
   - `--json` never asks, because prompting inside a document nobody is
     reading would be worse than refusing. Use `--yes`.
   - A dry run confirms everything in the plan, because it launches nothing
     and the point of a dry run is to see the whole command list.
4. **The device owner**, when `security.requireApproval` is on. The approval
   gate runs immediately before anything is launched, and only when something
   will actually run — so a `macup update` that would change nothing does not
   put a Touch ID prompt in front of you, and a scripted one does not fail on
   a prompt it could not show. A refused or unavailable approval is exit
   code 77 and nothing is changed.
5. **Policy again.** The execution engine re-reads the configuration file
   immediately before each item, so a rule you change after reading the plan
   still applies.

A run where nothing is confirmed changes nothing and records nothing: what
MacUp decided is on screen, and there was no attempt to log. Once MacUp
attempts an item, the attempt is in history whether it succeeded, failed, or
was abandoned.

Items run strictly one after another. After a failure MacUp stops before any
remaining `high` or `unknown` risk change, because a failure means it no
longer knows the state of the machine as well as the plan assumed.

While an update runs, MacUp prints the package manager's own output, a line
at a time, under the command it is running, so a long build is visibly
working.

Ctrl+C stops the run after the item that is running: nothing further is
started, and the report says which items ran and which never did. The running
command itself is left to finish, because stopping a package manager part-way
can leave the item with no usable version. A second Ctrl+C quits MacUp at
once; the running command may carry on by itself.

## Approval before a change

MacUp can require the device owner's approval before it changes anything:

```bash
macup security require on
macup security            # which sensor this Mac has, and whether MacUp asks
```

macOS does the asking, with whatever the Mac has — Touch ID, Face ID, or
Optic ID on hardware that has one — and your login password or an unlocked
Apple Watch as the fallback. MacUp never sees your fingerprint, your face, or
your password: it asks macOS a yes-or-no question and is told yes or no.

**This is a confirmation, not a lock.** MacUp runs as you, so anyone at your
unlocked Mac can run `brew`, `npm`, or `mise` directly without it, and can
edit `~/.config/macup/config.json` to turn it off. What it buys is a
deliberate step in front of every change MacUp itself makes, in the CLI and
the app alike.

- Every change goes through this one gate: `macup update` before it launches
  anything, and the commands that write MacUp's configuration — `macup policy
  set|clear`, `macup exclude`, `macup provider enable|disable`, `macup
  schedule enable|disable`, and `macup security require` itself.
- Changing the setting is itself gated, by the rule in force at the time.
- MacUp refuses to require an approval this Mac could never give: if there is
  no usable sensor and no fallback, `macup security require on` fails rather
  than leaving you unable to change anything.
- No Mac has a Face ID sensor today. MacUp reads the sensor from macOS rather
  than assuming, so a Mac that ever has one needs no change here.

### The camera face match

MacUp also has a face check of its own, off by default:

```bash
macup security face enroll     # a few pictures, then the camera closes
macup security face            # enrolled? how well can it match?
macup security face forget     # delete it
```

Be clear about what this is. macOS exposes no face-recognition API — Vision
finds *a* face in a picture, it does not tell you whose. So MacUp crops to the
face and compares Vision image feature prints, which measures how alike two
pictures look. **A photograph of the enrolled person passes.**

It is therefore a shortcut, never the thing that makes a change safe:

- It can only approve early. When it does not match, MacUp still runs the
  macOS prompt, so a bad match cannot lock you out.
- It does nothing unless `security.requireApproval` is also on. `macup config
  show` says so when it is not.
- What is stored is a list of numbers in `~/.local/state/macup/`, owner-only.
  No image is kept and nothing leaves the Mac. The camera is open only for the
  moment of capture, with the recording light on.
- `status` reports how far apart your own enrolled samples are. If that spread
  is wider than `security.faceMatchThreshold`, matching cannot work, and MacUp
  says so rather than letting you find out later.

## Scheduled checks

`macup schedule enable` writes `~/Library/LaunchAgents/com.macup.check.plist`
and loads it with `launchctl bootstrap`. It is a per-user LaunchAgent, not a
daemon: it runs as you, needs no administrator authorization, and there is no
background process between runs.

The agent runs exactly one command, which you can read in the property list
and in `macup schedule status`:

```text
/path/to/macup check --save-state --refresh
```

That is the same read-only check as `macup check`. Scheduled *updating* does
not exist: the agent is only ever allowed to run a check, and
`scripts/check-trust-invariants.sh` fails the build if that ever changes.
Nothing MacUp installs can update a package while you are not there — run
`macup update` yourself when you want a change.

- The report goes to `~/.local/state/macup/last-check.json`; `macup schedule
  status` summarises it.
- Diagnostics go to `~/.local/state/macup/scheduler.log`.
- `RunAtLoad` is false, so enabling a nightly check does not also run one at
  every login.
- launchd runs a missed calendar job once after the Mac wakes, so a machine
  asleep at the chosen time still checks.
- `--no-refresh` drops the metadata refresh. Without a refresh, `brew
  outdated` reads local metadata that may be weeks old, so a scheduled check
  would report almost nothing. A refresh updates package lists only.
- Weekly defaults to Sunday when no `--weekday` is given; `macup schedule
  status` always shows the day it resolved to.
- `macup schedule disable` unloads the job and deletes the property list.
  Nothing is left behind.

`macup schedule status` reports rather than repairs. It says when the
installed agent no longer matches the configuration, when the scheduled
binary has moved or been deleted, and when launchd does not have the job
loaded.

### What `--refresh` does

Without `--refresh`, Homebrew results come from Homebrew's local metadata
(MacUp sets `HOMEBREW_NO_AUTO_UPDATE=1`, because `brew outdated` would
otherwise run `brew update` first), and macOS results come from the last
scan (`softwareupdate --list --no-scan`).

With `--refresh`, MacUp first runs:

- `brew update` — updates Homebrew itself and its package lists. It does
  not upgrade any installed formula or cask.
- `softwareupdate --list` — a fresh scan for macOS updates.

npm and mise always query their registries, so `--refresh` changes nothing
for them.

## Output

Human output is plain text. ANSI styling is used only when stdout is a
terminal, and never when `NO_COLOR` is set or `TERM=dumb`. Every state is
also stated in words; color is decoration. All provider-supplied text is
sanitized so control characters and bidirectional overrides are shown as
visible `\u{…}` escapes instead of reaching the terminal. In JSON output
the same characters are written as `\uXXXX` escapes, which JSON readers
decode back to the original text.

A check says "up to date" only when it is complete. If a provider failed,
listed updates MacUp could not read, or reported lookups it could not
finish, the output says so and the check exits with status 2.

## Exit status

| Code | Meaning |
| --- | --- |
| 0 | The command completed. For `check`, every enabled provider was checked or is simply not installed. Updates being available is not an error, and neither is `update` deciding to change nothing. |
| 2 | `check`, `plan`, or `update` completed but at least one provider failed or left updates out (listed updates MacUp could not read, or lookups the provider could not finish); results are partial. |
| 3 | The configuration is invalid. Read-only commands still ran (a file other users could change is ignored, so defaults were used); MacUp will change nothing until it is fixed, and `policy set`/`clear`, `exclude`, and `provider enable`/`disable` refuse rather than rewrite a file they misread. When `MACUP_CONFIG_DIR`/`MACUP_STATE_DIR`/`MACUP_LAUNCH_AGENTS_DIR` is not absolute, nothing runs. |
| 4 | `update` ran and at least one item failed. Everything it did attempt is in `macup history`. |
| 5 | `doctor` found at least one warning or error. Notes alone are exit code 0. |
| 64 | Invalid command-line usage: an argument that is not a package ID, an unknown provider, an unknown policy, `--limit` below 1, or (for `plan` and `update`) a package ID with no update available. `update` changes nothing in that case. For `explain`, an item MacUp knows nothing about: its provider does not list it, is turned off, or is not installed. |
| 77 | The device owner did not approve the change, or MacUp could not ask. Nothing was changed. |
| 130 | Interrupted with Ctrl+C. |
| 1 | Unexpected internal error; `schedule enable`/`disable` failing to install, remove, or record the schedule; and `history` failing to read its file. |

When several apply, the first in this order wins: 130, then 64, then 4, then
3, then 2. `macup doctor` is the exception: it reports a configuration
problem as a finding rather than as exit code 3, so it answers 5.

Two things deliberately do **not** change the exit code:

- An update that ran but could **not be confirmed** afterwards. The command
  succeeded and the machine did change, so calling it a failure would make
  scripts retry an update that already happened. MacUp says so loudly in the
  output, counts it in `summary.unverified`, and records the verification
  outcome in history — it just never claims the update was verified.
- Updates being available at all. `macup check` and `macup plan` exit 0 with
  a full list.

Ctrl+C cancels cleanly: read-only provider commands are stopped (SIGTERM,
then SIGKILL after a grace period), a command that is changing something is
left to finish, the partial report is marked `"cancelled": true`, and
`update` reports which items ran and which never started. A second Ctrl+C
exits immediately.

## JSON (schema version 1)

Every JSON document has `schemaVersion` and `kind`. Within a schema version
fields may be added; renaming or removing a field requires a new version.
Dates are ISO 8601 (UTC); durations are seconds.

### `macup check --json` (`"kind": "check"`)

| Field | Meaning |
| --- | --- |
| `schemaVersion` | `1` |
| `kind` | `"check"` |
| `macupVersion` | MacUp's version |
| `mode` | `"readOnly"` or `"metadataRefresh"` (with `--refresh`; still no package changes) |
| `startedAt`, `finishedAt` | When the check ran |
| `cancelled` | `true` if interrupted |
| `configuration` | `path`, `source` (`defaults`/`file`), `valid`, `automaticModificationsAllowed`, `issues[]` |
| `providers[]` | One entry per checked provider, below |
| `updates[]` | Every available update in provider order, below |
| `summary` | `updatesAvailable`, `providersChecked`, `providersUnavailable`, `providersDisabled`, `providersWithErrors`, `providersIncomplete` (finished without errors but left updates out) |
| `commands[]` | Every command run or refused: `command` (display form, redacted), `effect`, `outcome` (`exited`, `signaled`, `timedOut`, `cancelled`, `refused`, `failedToLaunch`), `exitStatus`, `startedAt`, `durationSeconds` |

Provider entries: `provider`, `displayName`, `availability` (`available`,
`unavailable`, `disabled`, `failed`), `capabilities[]`, `executable`
(`path`, `canonicalPath`, `source`), `version`, `facts[]` (`key`, `label`,
`value`), `installedCount` (null when unknown), `updateCount` (null when
the check failed), `unreadableUpdates` (listed updates MacUp could not read,
not counted in `updateCount`), `resultsIncomplete` (the results are known
to be missing something), `items[]` (only with `--inventory`), `findings[]`,
`errors[]` (`operation`, `error`), `durationSeconds`.

Update entries: `id` (for example `brew:git`, `npm:@scope/name`,
`mise:node`, `macos:<softwareupdate label>`), `kind` (`formula`, `cask`,
`globalPackage`, `tool`, `systemUpdate`), `displayName`,
`installedVersion` (may be absent), `availableVersion`, `versionChange`
(`major`, `minor`, `patch`, `build`, `revision`, `prerelease`, `none`,
`downgrade`, `unknown`), `signals[]`, `risk` (`level`: `low`, `moderate`,
`high`, `unknown`; `reasons[]`), `ownership.links[]`, `notes[]`, `details`
(provider-specific strings with stable keys).

Errors (`MacUpError`): `kind` (`providerUnavailable`, `commandFailed`,
`parseFailed`, `policyDenied`, `authorizationRequired`, `timeout`,
`cancelled`, `verificationFailed`, `ambiguousOwnership`, `unsupported`,
`configurationInvalid`), `message`, and optional `detail`, `command`,
`exitStatus`, `recoverySuggestion`. Details are redacted.

`Tests/MacUpCLITests/JSONSchemaTests.swift` contains a complete golden
example and fails if the encoding changes.

### `macup plan --json` (`"kind": "plan"`, schema version 1)

| Field | Meaning |
| --- | --- |
| `createdAt` | When the plan was built |
| `intent` | `interactive` from the CLI; `unattended` exists for a run with nobody at the Mac |
| `planned[]` | `candidate` (an update entry as above), `decision`, and `plan` |
| `skipped[]` | `item`, `displayName`, `currentVersion`, `proposedVersion`, `decision`, `reason`, `error` |
| `summary` | `allowed`, `needsConfirmation`, `deniedByPolicy`, `unplannable` |
| `configuration` | As in `check` |
| `unmatchedSelection[]` | Package IDs you named that no provider offered an update for |
| `providers[]` | The provider reports behind the plan, so a failed provider is visible |
| `cancelled` | `true` if interrupted |

`decision`: `item`, `action` (`allow`, `confirm`, `deny`), `policy` (the
effective one, never `inherit`), `source` (`item`, `provider`, `global`,
`providerDisabled`, `providerPin`, `skippedVersion`, `risk`, `configuration`,
`unattended`), `reason`, `escalated` (risk turned an automatic update into a
confirmation), and `note` (your note on the item, verbatim; absent when there
is none).

`plan` (an `ExecutionPlan`): `id`, `createdAt`, `item`, `currentVersion`,
`proposedVersion`, `risk`, `rationale`, `steps[]`, `expectsNetwork`,
`mayRequirePrivilege`, `mayRequireRestart`, `mayChangeUserConfiguration`,
`verification[]`, `rollback` (`availability`: `available`, `unavailable`,
`unknown`; `explanation` — MacUp never claims rollback without a tested
strategy). Each step: `summary`, `invocation` (`executable` and
`arguments[]`, the exact things MacUp will launch), `effect`,
`expectsNetwork`, `mayRequirePrivilege`, `timeoutSeconds`.

### `macup explain --json` (`"kind": "explain"`, schema version 1)

| Field | Meaning |
| --- | --- |
| `createdAt`, `item` | When the explanation was built, and the package ID it is about |
| `status` | `updateAvailable`, `upToDate` (installed, no update), `updateUnknown` (installed, but the update check failed), `notFound`, `providerDisabled`, `providerNotFound`, or `checkFailed` |
| `summary` | One sentence saying what MacUp found |
| `update` | The update, as in `check` (absent when there is none) |
| `versionDifference` | `parts[]` (`name`, `from`, `to`), when both versions are clearly numeric |
| `releaseInfoLink` | `title` and `url`, when the provider gives a page for the release |
| `installed` | The item as its provider lists it installed: `installedVersions[]`, `activeVersion`, `pinnedByProvider`, `ownership`, `details` |
| `policy` | `policy` (effective, never `inherit`), `source` (`item`, `provider`, `global`), `rule` (where it lives in the file, such as `items.brew:git.policy`), and `decision` (as in `plan`) when there is an update to decide about |
| `plan` | The `ExecutionPlan` MacUp would run, as in `plan`; absent when it would run nothing |
| `skipped` | Why MacUp would run nothing for an update it found, as in `plan`'s `skipped[]` |
| `history` | `entries[]` (the item's own, newest first, as in `history`), `limit`, `moreAvailable`, `unreadableLines`, `problem` |
| `providerReport` | The provider's entry from the check, as in `check`, without `items` |
| `configuration`, `cancelled` | As in `check` |

An item MacUp knows nothing about still gets a document, with exit code 64,
so a script can read why. Exit code 2 means the item's provider could not be
checked completely, so the explanation may be missing something; 3 means the
configuration is invalid, so the decision is to change nothing.

### `filter` (`check` and `plan`, with `--risk`, `--policy`, `--attention`, or `--sort`)

Without these options neither document has a `filter` field and both are
exactly as described above. With any of them, `updates[]` (for `check`) or
`planned[]` and `skipped[]` (for `plan`) hold only the entries that match, in
the requested order, and the document gains:

| Field | Meaning |
| --- | --- |
| `riskLevels[]` | The risk levels kept; empty when risk did not narrow the list |
| `policies[]` | The policies in effect kept; empty when policy did not narrow the list |
| `needsAttentionOnly` | `true` with `--attention` |
| `sort` | `provider`, `risk`, `name`, or `change` |
| `shown` | Entries the filter kept |
| `hidden` | Entries it left out |

Everything else still describes the whole run: `summary`, every provider's
`updateCount`, and the exit status count every update, so a filtered document
can never read as a Mac with fewer updates than it has. A plan entry whose
update MacUp cannot find is kept, never hidden. `--save-state` always saves the
unfiltered check.

### `macup update --json` (`"kind": "update"`, schema version 1)

| Field | Meaning |
| --- | --- |
| `origin` | `cli` |
| `dryRun` | `true` when nothing was launched |
| `startedAt`, `finishedAt`, `cancelled` | When the run happened, and whether it was interrupted |
| `executed[]` | `item`, `displayName`, `plan`, `result`, `verification` |
| `skipped[]` | Every item MacUp did not change, with the reason (same shape as `plan`'s) |
| `summary` | `attempted`, `succeeded`, `failed`, `skipped`, `verified`, `unverified` |

`result`: `planID`, `item`, `outcome` (`succeeded`, `failed`, `skipped`,
`cancelled`, `timedOut`), `startedAt`, `finishedAt`, `steps[]` (`command`
— the redacted display form, `exitStatus`, `durationSeconds`,
`errorExcerpt`), `error`. `verification`: `item`, `outcome` (`verified`,
`targetNotReached`, `failed`, `notPerformed`), `expectedVersion`,
`observedVersion`, `observedState` (absent unless the read-back showed more
than a version, for example that no version is linked), `message`. It is
present after a success, and also after an attempt that started a command and
did not succeed, where it is what that attempt left; `summary.verified` counts
only attempts that succeeded and were confirmed.

### `macup doctor --json` (`"kind": "doctor"`, schema version 1)

`startedAt`, `finishedAt`, `findings[]` (most severe first, then by
identifier: `id` such as `homebrew.multipleInstallations`, `severity`
(`error`, `warning`, `info`), `provider`, `title`, `detail`,
`recommendation`), `providers[]`, `configuration`, `summary` (`errors`,
`warnings`, `notes`, `checksRun`), `cancelled`.

### `macup history --json` (`"kind": "history"`, schema version 1)

`path`, `limit`, `items[]` (the package IDs asked for; empty for every
item), `search` (absent when there was none), `entries[]` (newest first,
after both), `unreadableLines` (lines MacUp could not decode — reported,
never guessed at), `olderEntriesNotRead`.

Each entry: `schemaVersion`, `id`, `timestamp`, `origin` (`cli`, `gui`,
`scheduled`), `item`, `versionBefore`, `versionTarget`, `versionAfter` (what
MacUp read back, after a success or after an attempt that started a command
and did not succeed), `stateAfter` (what else that read-back showed, when
there was something), `command` (redacted display form), `outcome`,
`verification`, `errorSummary`, `skipReason`, `durationSeconds`. Fields are
only ever added and every added one is optional, so lines written by an
earlier MacUp still decode; they simply lack the newer fields.

### Other documents

- `macup provider list --json` → `"kind": "providerList"`: `macupVersion`,
  `providers[]` (as above, detection fields only), `commands[]`.
- `macup policy list --json` → `"kind": "policyList"`: `defaultPolicy`,
  `confirmMajorUpdates`, `providers[]` (`provider`, `enabled`, `policy` as
  written, `effectivePolicy`, `explicit` — false when the row is MacUp's
  built-in default rather than something in your file, `path`, `source`),
  `items[]` (`item`, `policy`, `effectivePolicy`, `path`, `source`, and
  `skipVersion` and `note` when set), `unreadableItemKeys[]`,
  `automaticModificationsAllowed`, `configurationFile`.
- `macup policy set|clear|skip|unskip|note --json`, `macup exclude --json`,
  and `macup provider enable|disable --json` → `"kind": "policyChange"`:
  `configurationFile` and `changes[]` (`subject` (`{"kind": "item"|"provider"
  |"global", "id": …}`), `setting` (`policy`, `enabled`, `skipVersion`, or
  `note`), `previousValue`,
  `newValue` (null when the rule was removed), `changed` (false when the
  configuration already said this and nothing was written), `path`,
  `summary`, `warnings[]`).
- `macup config show --json` → `"kind": "configuration"`: `path`, `source`,
  `valid`, `automaticModificationsAllowed`, `issues[]`, `configuration`.
- `macup config path --json` → `"kind": "configPaths"`: `configFile`,
  `configDirectory`, `stateDirectory`, and their `…Source` (`standard` or
  `environment`).
- `macup security status --json` → `"kind": "security"`: `requireApproval`,
  `allowPasswordFallback`, `biometry` (`touchID`, `faceID`, `opticID`,
  `none`), `biometryDisplayName`, `biometricsAvailable`, `fallbackAvailable`,
  `unavailableReason`.
- `macup security face status --json` → `"kind": "securityFace"`: `enabled`,
  `enrolled`, `sampleCount`, `enrolledAt`, `sampleSpread`, `threshold`,
  `cameraPresent`, `cameraAllowed`, `storedAt`, `problem`.
- `macup schedule status --json` → `"kind": "schedule"`:
  `enabledInConfiguration`, `schedule` (for example `"every day at 23:00"`),
  `refreshesMetadata`, `label`, `agentPath`, `agentInstalled`, `agentLoaded`
  (null when MacUp could not ask launchd), `agentMatchesConfiguration` (null
  when no agent is installed), `command` (the exact command launchd runs),
  `executablePath`, `executableExists`, `nextRun`, `logPath`, `warnings[]`,
  and `lastCheck` (`path`, `finishedAt`, `updatesAvailable`,
  `providersWithErrors`, `unreadable`) when a saved report exists.
