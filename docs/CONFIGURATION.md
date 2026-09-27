# Configuration

## Locations

One canonical scheme, shared by the CLI and (later) the app:

| What | Where |
| --- | --- |
| Configuration | `~/.config/macup/config.json` |
| State (history, logs — later phases) | `~/.local/state/macup/` |

`XDG_CONFIG_HOME` and friends are deliberately **not** honored: an app
launched from Finder does not see shell variables, so honoring them would
let the CLI and the app read different policies.

`MACUP_CONFIG_DIR` and `MACUP_STATE_DIR` override the directories for
testing and experiments. They must be absolute paths; anything else is a
configuration error (exit status 3), never a guess.

`macup config path` prints the locations.

## Schema (version 1)

```json
{
  "schemaVersion": 1,
  "global": { "defaultPolicy": "ask", "confirmMajorUpdates": true },
  "providers": {
    "homebrew": { "enabled": true, "policy": "ask" },
    "npm": { "enabled": true, "policy": "ask", "executablePath": "/opt/homebrew/bin/npm" },
    "mise": { "enabled": true, "policy": "ask" },
    "macos": { "enabled": true, "policy": "ask" }
  },
  "items": {
    "npm:@anthropic-ai/claude-code": { "policy": "ask" },
    "brew:postgresql": { "policy": "ignore" }
  },
  "schedule": { "enabled": false, "frequency": "daily", "time": "23:00" },
  "privacy": { "telemetry": false }
}
```

| Key | Values | Default |
| --- | --- | --- |
| `schemaVersion` | `1` (required) | — |
| `global.defaultPolicy` | `auto`, `ask`, `ignore` | `ask` |
| `global.confirmMajorUpdates` | `true`/`false` | `true` |
| `providers.<id>.enabled` | `true`/`false` | `true` |
| `providers.<id>.policy` | `auto`, `ask`, `ignore`, `inherit` | `inherit` |
| `providers.<id>.executablePath` | absolute path to `brew`/`npm`/`mise` | search |
| `items.<package-id>.policy` | `auto`, `ask`, `ignore`, `pin`, `inherit` | — |
| `schedule.enabled` | `true`/`false` | `false` |
| `schedule.frequency` | `daily`, `weekly` | `daily` |
| `schedule.time` | `HH:mm`, 24-hour | `23:00` |
| `schedule.weekday` | `monday` … `sunday` | — |
| `privacy.telemetry` | `true`/`false` (MacUp has no telemetry) | `false` |

Omitted sections take the defaults above. When no file exists, every
provider is enabled, everything is Ask First, scheduling is off, and there
is no telemetry.

Phase 1 uses `providers.<id>.enabled` (disabled providers are never run)
and `providers.<id>.executablePath`. Policies are stored and validated now
and enforced from Phase 2. The `schedule` section is stored and validated
too, but nothing reads it yet: MacUp installs no launchd agent and runs no
scheduled check until Phase 6, so `schedule.enabled` has no effect. `macup
config show` says so when the file turns it on.

## Validation fails closed

Anything MacUp cannot interpret with certainty is an **error**, and any
error disables automatic modification until it is fixed
(`macup config show` lists each problem with its location; exit status 3):

- invalid JSON, a missing or non-integer `schemaVersion`, or a schema
  newer than this MacUp understands;
- unknown keys at any level — a typo such as `"enabeld": false` must not
  silently leave a provider enabled;
- unknown providers, invalid package IDs (`"brew postgresql"`), policies
  outside the allowed set for their level (`pin` at provider level; `pin`
  or `inherit` as the global default), malformed schedule times;
- an `executablePath` that is relative or not named after the tool;
- a file or directory that is owned by another user or writable by group
  or others. For a symlinked file, the directory holding the file it points
  to is checked as well. The checks and the read use the same open file, so
  a file swapped in between is never trusted.

Warnings do not disable anything: `auto` for macOS (macOS is always Ask
First in v0.1), `telemetry: true` (there is no telemetry), and a
configuration file that is a symlink (readable; MacUp will not replace it).

A file that other users could change is **ignored entirely**: built-in
defaults are in effect until it is fixed, so it can neither choose which
executables MacUp runs nor turn providers off. Otherwise, if the file is
structurally valid but has errors, read-only commands still honor its
`enabled` flags and any `executablePath` that passes the rules above; if it
cannot be decoded at all, they use the defaults. Either way automatic
modification stays off.

## Writing (used by later phases)

`ConfigurationStore.save` writes atomically: a new owner-only (`0600`)
temporary file created with `O_EXCL | O_NOFOLLOW` in the same directory,
`fsync`, then `rename` over the destination, then `fsync` of the
directory. It creates the directory as `0700`, refuses to write into a
directory other users can modify, and refuses to replace a symlink.

## Migrations

Migrations transform the JSON document one schema version at a time.
Loading an older file migrates it in memory only; the file changes only
when MacUp next saves, and `persistMigration` first writes a backup next
to it (`config.json.backup-v<old>-<UTC timestamp>`, owner-only, never
overwriting). An invalid file is never migrated. Schema 1 is the first
schema, so no migrations exist yet; the mechanism is covered by tests.
