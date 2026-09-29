# UX Specification

## Tone

Native, calm, precise, transparent.

Do not use:
- fake “97% healthy” scores
- scareware language
- flashing warning visuals for routine updates
- dark patterns around telemetry or updates
- “magic” without explanation

## Main app

### Navigation

Sidebar order: Dashboard, Providers, Updates, Features, Doctor, History, with
Settings at the foot.
⌘1 to ⌘6 open them in that order, from the View menu. ⌘F searches the Updates
list.

### Dashboard

```text
MacUp

5 updates available
[ Review Updates ]

Pending Updates
  @anthropic-ai/claude-code   npm · Ask First · Low      2.1.282 → 2.1.284  ›
  npm                         npm · Ask First · High     11.17.0 → 12.1.0   ›

Ignored and Held
  mysql     Pin     held at its current version   9.7.1 → 26.7.0_2  [Unpin]
            “waiting for PHP 8.4 support”
  node      Skipped you skipped 26.1.0            24.19.0 → 26.1.0  [Stop Skipping]
  wget      Ignore  no update right now                             [Stop Ignoring]

Last checked: Today, 5:42 PM
```

Pending updates come first: everything that could still run. Items a rule
leaves alone come under them, with the reason, never hidden. Only a rule on
the item itself can be cleared from here.

### Providers

One section per provider MacUp knows, whether or not this Mac has it: found
or not, version, the exact executable and the facts behind it, the update
count, a switch that turns the provider on or off, and the rule its items
inherit (Use the Default, Auto Update, Ask First, Ignore). Same rules as
`macup provider enable|disable` and `macup policy set <provider>`.

### Finding an update

The Updates screen has a search field (name, package ID, or provider), a
Filter menu (provider, risk, the policy in effect, Needs Attention), and a
Sort menu (grouped by provider, the default; risk, highest first; name; size
of change, largest first). `macup check` and `macup plan` take the same
filter and orders (`--risk`, `--policy`, `--attention`, `--sort`); both come
from MacUpCore, so the two cannot disagree.

A filter never quietly shortens the list. While it hides anything, a bar
above the list says so, with Show All:

```text
3 updates hidden by the current filter          [Show All]
Showing: high risk
```

The dashboard, the sidebar badge, and the menu bar always count every update,
and Review Updates covers every update, including the hidden ones. Opening an
update from the dashboard clears a filter that would hide it.

Needs Attention is one explicit list of signals in MacUpCore
(`RiskSignal.needingAttention`): an earlier install that did not finish, and
an update that will be built from source.

### Update row

```text
Claude Code
2.1.282 → 2.1.290
npm · Ask First · Moderate

Managed by:
npm → Node 24.19.0 → mise

[Update] [Policy ▾] [Details]
```

### Details

Show:
- ownership chain
- current/target
- what changes: each part of the version (major, minor, patch, build,
  pre-release, packaging revision), from and to, worked out from the two
  version strings only; nothing when a version cannot be parsed
- a link to read about the release when the provider gives one (npm's page
  for that version, Homebrew's homepage). Only `https` addresses; MacUp
  never fetches the page itself
- detected source
- risk/reason
- exact executable
- argument list
- config/restart/admin effects
- verification behavior
- rollback availability truthfully
- whether it runs as a service right now (it keeps the old version until it
  restarts; MacUp never restarts it), and for a database moving to a new
  major version, that its data may be converted for good: back up first.
  Both also get one line in the row
- What Depends on It (Homebrew formulae): a button, since the answer is slow
  to work out, with progress, Cancel, and the answer's time; never shown for
  an item MacUp cannot ask about

### Policies

Each item:
- Inherit
- Auto Update
- Ask First
- Ignore
- Pin (when supported)

Providers also have default policy.

### Review batch

```text
Ready to update 4 items

Will update:
✓ git
✓ wget
✓ TypeScript
✓ Claude Code

Will not update:
— PostgreSQL (Ignored)
— Node (Ask First / major change)

Potential admin authorization: none
Restart required: none

[Show Commands]
[Update 4 Items]
```

## Menu bar

Keep it compact:
- status
- number of available updates
- Review Updates
- Check Now
- Open MacUp
- Last check

Do not put a one-click blind “Update Everything” action in the menu bar for v1.

## Error design

Error should answer:
- what failed?
- what did MacUp run?
- what changed, if anything?
- was verification completed?
- what should the user do next?
- was execution stopped?

## Accessibility

- full keyboard navigation
- VoiceOver
- labels for icons
- status conveyed by text + icon, not color alone
- platform-native focus behavior
- respect reduced motion
