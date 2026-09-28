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
  "schedule": { "enabled": false, "frequency": "daily", "time": "23:00", "refresh": true },
  "privacy": { "telemetry": false },
  "security": {
    "requireApproval": false,
    "allowPasswordFallback": true,
    "faceUnlock": false,
    "faceMatchThreshold": 0.6
  }
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
| `schedule.weekday` | `monday` … `sunday` | Sunday, for a weekly schedule |
| `schedule.refresh` | `true`/`false` — refresh package metadata before a scheduled check | `true` |
| `privacy.telemetry` | `true`/`false` (MacUp has no telemetry) | `false` |
| `security.requireApproval` | `true`/`false` — ask the device owner before MacUp changes anything | `false` |
| `security.allowPasswordFallback` | `true`/`false` — let the login password or an unlocked Apple Watch stand in for the sensor | `true` |
| `security.faceUnlock` | `true`/`false` — let MacUp's own camera face match approve early | `false` |
| `security.faceMatchThreshold` | distance greater than 0 and no more than 5; smaller is stricter | `0.6` |

Omitted sections take the defaults above. When no file exists, every
provider is enabled, everything is Ask First, scheduling is off, and there
is no telemetry.

Every key above is now read and acted on. `providers.<id>.enabled` decides
which providers run at all; `providers.<id>.executablePath` decides which
installation they run. The policy keys are resolved by `PolicyEngine` —
per-item, then provider, then global default — and re-read from this file
immediately before any change, so editing it takes effect on the next item
rather than the next run (`docs/TRUST_AND_SECURITY.md`).

The `security` section is what `macup security require` writes. Turning
`requireApproval` on by hand works too, but MacUp will then refuse every
change if this Mac cannot ask you anything; the command checks that first.
Editing this file is always possible — it is your file, and MacUp never locks
you out of it.

The `schedule` section describes the scheduled read-only check. Change it
with `macup schedule enable` and `macup schedule disable` rather than by
hand: those commands also install and remove the launchd agent that does the
work. Editing `schedule.enabled` in the file on its own schedules nothing —
`macup schedule status` will say so.

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

"Stays off" is concrete: `PolicyEngine` returns `deny` for every item, with
the reason that MacUp cannot tell which items you excluded, and `PolicyEditor`
refuses to write. Nothing is changed until the configuration is fixed.

## Editing policy through `PolicyEditor`

`PolicyEditor` is the one place MacUp changes a rule. `macup policy set`,
`macup policy clear`, `macup provider enable`, `macup provider disable`, and
the app's policy controls all go through it, so there is a single source of
truth for what a policy edit is allowed to do (CLAUDE.md §12). It refuses
more than it accepts, and the refusals are the interesting part.

### A package ID is validated before anything is written

An item name is parsed as a `PackageID` first. A typo or an unsupported
ecosystem is rejected without the file being opened, so a rule that could
never match anything does not get stored as if it might.

### MacUp will not rewrite a configuration it could not read

If the configuration has any error-severity problem, an edit is refused and
the file is left exactly as it was.

The reason is the same one that makes an unreadable configuration deny every
change: **the rules saying which items are excluded are exactly the rules
MacUp could not read.** MacUp saves the file by re-encoding what it
understood. Writing back a file it misread would replace the parts it misread
with its own idea of them — which could silently drop the `ignore` rule the
user was relying on. Refusing to write is the only option that cannot lose
somebody's exclusions.

`macup config show` lists each problem with its location, and the refusal
repeats them, so fixing the file and trying again is the whole recovery path.

### What that means for a file containing keys MacUp does not know

An unrecognized key at any level is already a configuration **error** (see
"Validation fails closed" above). So a file containing one is refused for
editing, and left byte-for-byte as the user wrote it.

That is the intended outcome rather than a side effect. It keeps the unknown
key, and it keeps the user's own formatting of everything else. Two
alternatives were considered and are worse:

- **Re-encode and drop the key.** MacUp would silently delete something the
  user wrote, possibly a setting from a newer MacUp they are about to go back
  to.
- **Edit the JSON document in place.** `JSONSerialization` re-prints the
  numbers it parsed, so a hand-written `"faceMatchThreshold": 0.6` would come
  back as `0.59999999999999998`. An edit tool that quietly rewrites unrelated
  values is not a tool anyone should trust with a policy file.

If MacUp adds a key later, an older MacUp reading that file will refuse to
edit it and say which key it did not recognize. That is a clear message and a
file that still works, which is better than a clean write and lost settings.

### An edit that would break the configuration is refused before writing

After applying a change in memory, the result is validated again. If the
change would introduce an error, nothing is written and the error names the
path it would have been at.

This is what stops MacUp from putting the configuration into the state that
disables automatic modification. `pin` cannot land on a whole provider, and
the global default cannot become `pin` or `inherit` — both are errors, and
either would leave the user unable to change anything until they edited the
file by hand. An edit that validated its input but not its own output would
make MacUp the cause of the very state it fails closed on.

Warnings do not block an edit. They are returned with the change, so a
caller can say "stored, but it has no effect in this version" — setting
`auto` for macOS, for example, which is accepted and recorded and still
always asks.

### What a change reports

An edit returns the value it replaced, the value it wrote, and where in the
file it lives (`items.brew:git.policy`, `providers.npm.enabled`,
`global.defaultPolicy`). When the configuration already said what was asked
for, nothing is written and the result says so plainly rather than claiming
success; clearing a rule that was never set reports that there was nothing to
clear.

A provider the file does not mention already has a value — the built-in
default — so an edit to it reports that value rather than "not set".

If the file was read at an older schema version, the edit is about to persist
the in-memory upgrade, so `persistMigration` writes the backup first (see
"Migrations" below).

## Writing

`ConfigurationStore.save` writes atomically: a new owner-only (`0600`)
temporary file created with `O_EXCL | O_NOFOLLOW` in the same directory,
`fsync`, then `rename` over the destination, then `fsync` of the
directory. It creates the directory as `0700`, refuses to write into a
directory other users can modify, and refuses to replace a symlink.

History (`~/.local/state/macup/history.jsonl`) is held to the same rules:
owner-only, never written through a symlink, never into a directory somebody
else could change, and trimmed by atomic replace. See
`docs/TRUST_AND_SECURITY.md`.

## Migrations

Migrations transform the JSON document one schema version at a time.
Loading an older file migrates it in memory only; the file changes only
when MacUp next saves, and `persistMigration` first writes a backup next
to it (`config.json.backup-v<old>-<UTC timestamp>`, owner-only, never
overwriting). An invalid file is never migrated. Schema 1 is the first
schema, so no migrations exist yet; the mechanism is covered by tests.
