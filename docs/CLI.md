# CLI reference

This version of MacUp is **read-only** about your packages: no command
installs, upgrades, removes, cleans, or prunes anything. Two commands write
MacUp's own files — `macup schedule enable` and `macup schedule disable`,
which record the schedule in the configuration and install or remove a
launchd agent. The scheduled job itself only runs `macup check`.

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
| `macup check --verbose` | Adds ownership chains, risk reasons, notes, and every command MacUp ran. |
| `macup check --save-state` | Also writes the report to `~/.local/state/macup/last-check.json`. This is how a scheduled check leaves its result behind. |
| `macup providers` / `macup provider list [--json]` | Shows which providers were found and exactly which installation MacUp uses. Runs detection only. |
| `macup config` / `macup config show [--json]` | Shows the configuration in effect and every problem with it. Never creates the file. |
| `macup config path [--json]` | Prints the configuration file and state directory locations. |
| `macup schedule` / `macup schedule status [--json]` | Shows whether a check is scheduled, when it next runs, and what the last one found. Read-only. |
| `macup schedule enable [--frequency daily\|weekly] [--time HH:mm] [--weekday <day>] [--no-refresh]` | Installs the launchd user agent that runs a read-only check, and records it in the configuration. |
| `macup schedule disable` | Removes the agent and clears the setting. |
| `macup security` / `macup security status [--json]` | Shows which sensor this Mac has and whether MacUp asks for approval. Read-only, no prompt. |
| `macup security require <on\|off> [--no-password-fallback]` | Turns the approval requirement on or off. |
| `macup --help`, `macup --version` | Help and version. |

The remaining commands in the CLI contract (`update`, `plan`, `doctor`,
`history`, `provider enable|disable`, `policy …`) arrive with Phases 2–4
and are intentionally absent rather than stubbed.

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

- Today the gated change is the schedule (`macup schedule enable|disable`).
  The execution engine uses the same gate when it arrives.
- Changing the setting is itself gated, by the rule in force at the time.
- MacUp refuses to require an approval this Mac could never give: if there is
  no usable sensor and no fallback, `macup security require on` fails rather
  than leaving you unable to change anything.
- No Mac has a Face ID sensor today. MacUp reads the sensor from macOS rather
  than assuming, so a Mac that ever has one needs no change here.

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
not exist in this version, because MacUp cannot modify a package at all yet.

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
| 0 | The command completed. For `check`, every enabled provider was checked or is simply not installed. Updates being available is not an error. |
| 2 | `check` completed but at least one provider failed or left updates out (listed updates MacUp could not read, or lookups the provider could not finish); results are partial. |
| 3 | The configuration is invalid. Read-only commands still ran (a file other users could change is ignored, so defaults were used); automatic modifications stay disabled. When `MACUP_CONFIG_DIR`/`MACUP_STATE_DIR`/`MACUP_LAUNCH_AGENTS_DIR` is not absolute, nothing runs. |
| 64 | Invalid command-line usage. |
| 77 | The device owner did not approve the change, or MacUp could not ask. Nothing was changed. |
| 130 | Interrupted with Ctrl+C. |
| 1 | Unexpected internal error, and `schedule enable`/`disable` failing to install, remove, or record the schedule. |

When several apply, the first in this order wins: 130, 2, 3.

Ctrl+C cancels a check cleanly: in-flight provider commands receive
SIGTERM (then SIGKILL after a grace period), and the partial report is
marked `"cancelled": true`. A second Ctrl+C exits immediately.

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

### Other documents

- `macup provider list --json` → `"kind": "providerList"`: `macupVersion`,
  `providers[]` (as above, detection fields only), `commands[]`.
- `macup config show --json` → `"kind": "configuration"`: `path`, `source`,
  `valid`, `automaticModificationsAllowed`, `issues[]`, `configuration`.
- `macup config path --json` → `"kind": "configPaths"`: `configFile`,
  `configDirectory`, `stateDirectory`, and their `…Source` (`standard` or
  `environment`).
- `macup security status --json` → `"kind": "security"`: `requireApproval`,
  `allowPasswordFallback`, `biometry` (`touchID`, `faceID`, `opticID`,
  `none`), `biometryDisplayName`, `biometricsAvailable`, `fallbackAvailable`,
  `unavailableReason`.
- `macup schedule status --json` → `"kind": "schedule"`:
  `enabledInConfiguration`, `schedule` (for example `"every day at 23:00"`),
  `refreshesMetadata`, `label`, `agentPath`, `agentInstalled`, `agentLoaded`
  (null when MacUp could not ask launchd), `agentMatchesConfiguration` (null
  when no agent is installed), `command` (the exact command launchd runs),
  `executablePath`, `executableExists`, `nextRun`, `logPath`, `warnings[]`,
  and `lastCheck` (`path`, `finishedAt`, `updatesAvailable`,
  `providersWithErrors`, `unreadable`) when a saved report exists.
