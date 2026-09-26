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

### Dashboard

```text
MacUp

7 updates available

Homebrew        3
npm             2
mise            1
macOS           1 review required

2 items ignored
1 item pinned

[ Review Updates ]

Last checked: Today, 5:42 PM
```

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
- detected source
- risk/reason
- exact executable
- argument list
- config/restart/admin effects
- verification behavior
- rollback availability truthfully

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
