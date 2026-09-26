# CLI reference

This version of MacUp is **read-only**. No command installs, upgrades,
removes, cleans, or prunes anything, and no command writes MacUp's
configuration.

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
| `macup provider list [--json]` | Shows which providers were found and exactly which installation MacUp uses. Runs detection only. |
| `macup config show [--json]` | Shows the configuration in effect and every problem with it. Never creates the file. |
| `macup config path [--json]` | Prints the configuration file and state directory locations. |
| `macup --help`, `macup --version` | Help and version. |

The remaining commands in the CLI contract (`update`, `plan`, `doctor`,
`history`, `provider enable|disable`, `policy …`) arrive with Phases 2–4
and are intentionally absent rather than stubbed.

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
visible `\u{…}` escapes instead of reaching the terminal.

## Exit status

| Code | Meaning |
| --- | --- |
| 0 | The command completed. For `check`, every enabled provider was checked or is simply not installed. Updates being available is not an error. |
| 2 | `check` completed but at least one provider failed; results are partial. |
| 3 | The configuration is invalid (or `MACUP_CONFIG_DIR`/`MACUP_STATE_DIR` is not absolute). Read-only commands still ran; automatic modifications stay disabled. |
| 64 | Invalid command-line usage. |
| 130 | Interrupted with Ctrl+C. |
| 1 | Unexpected internal error. |

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
| `summary` | `updatesAvailable`, `providersChecked`, `providersUnavailable`, `providersDisabled`, `providersWithErrors` |
| `commands[]` | Every command run or refused: `command` (display form, redacted), `effect`, `outcome` (`exited`, `signaled`, `timedOut`, `cancelled`, `refused`, `failedToLaunch`), `exitStatus`, `startedAt`, `durationSeconds` |

Provider entries: `provider`, `displayName`, `availability` (`available`,
`unavailable`, `disabled`, `failed`), `capabilities[]`, `executable`
(`path`, `canonicalPath`, `source`), `version`, `facts[]` (`key`, `label`,
`value`), `installedCount` (null when unknown), `updateCount` (null when
the check failed), `items[]` (only with `--inventory`), `findings[]`,
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
