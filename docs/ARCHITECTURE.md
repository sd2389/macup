# Architecture

## High-level

```text
                 ┌─────────────────┐
                 │   MacUp.app     │
                 │ SwiftUI/MenuBar │
                 └────────┬────────┘
                          │
┌──────────────┐   ┌──────▼────────┐
│  macup CLI   │──►│   MacUpCore   │
└──────────────┘   └──────┬────────┘
                          │
                  ┌───────▼────────┐
                  │ Policy + Plan  │
                  └───────┬────────┘
                          │
                  ┌───────▼────────┐
                  │ ExecutionEngine│
                  └───────┬────────┘
                          │
             ┌────────────┼─────────────┐
             │            │             │
          Homebrew       npm          mise
             │            │             │
             └────────────┼─────────────┘
                          │
                    macOS provider
```

## Boundary rules

### UI
Displays state and sends intents. No provider-specific shell logic.

### CLI
Parses commands and presents output. No duplicated provider policy logic.

### Core
Owns models, policy, planning, provider interfaces, execution, verification, diagnostics, history.

### Provider
Translates provider-specific machine state into MacUp models and constructs provider-specific plans.

`UpdateProvider` also answers for the environment its own commands need
(`executionEnvironment(context:)`). That is not a convenience: see "Why the
provider supplies the environment" below.

### Policy
`PolicyEngine` answers what MacUp may do with an item and why. It reads the
configuration and returns a decision — allow, confirm, or deny — with one
human-readable sentence. Nothing else in MacUp decides that question.

`PolicyEditor` is the single door for *changing* a rule, so `macup policy
set/clear`, `macup provider enable/disable`, and the app's policy controls
cannot drift apart. `PolicyListing` answers "what are my rules?" and resolves
inheritance through the same engine, so a listing can never disagree with the
decision the user will actually get.

### Planning
`UpdatePlanner` turns candidates into `PlannedUpdate` and `SkippedUpdate`
values. It launches nothing: a plan is a description. Every candidate policy
refused becomes a skip carrying the decision and its reason, so an ignored or
pinned item cannot reach the list a bulk action would run.

### Execution
`ExecutionEngine` is the only place in MacUp that launches a modifying
command. `ExecutionGuard` and `ModifyingCommandRules` bound what it may
launch; see "Two allowlists" below.

### History
`HistoryStore` appends one redacted JSON object per line to
`history.jsonl` in the state directory. Every attempt and every skip is
recorded with its reason.

### Diagnostics
Doctor reads the result of one read-only check and says what it saw. Each
check is a small type driven only by a `DiagnosticInput`, so a check cannot
reach for a fact nobody gathered, and every check is testable from a
synthetic provider report. Doctor explains; it never fixes.

### CommandRunner
The only normal path for launching external executables.

### Scheduler
Owns the launchd user agent that runs a scheduled check: building the property
list, loading and unloading it through `launchctl`, and reporting what is
actually installed. It is a user agent, never a daemon, and the only command it
can schedule is `macup check`. The label (`com.macup.check`) and the agent path
are MacUp's own constants, so no part of the `launchctl` invocation comes from
user text.

## Data flow

### Check
```text
detect providers
  -> inventory/outdated concurrently
  -> normalize candidates
  -> evaluate current policy
  -> present
```

### Update
```text
candidate
  -> policy decision        (PolicyEngine, with the reason)
  -> risk assessment        (already on the candidate)
  -> execution plan         (the owning provider; runs nothing)
  -> presented for review   (exact executable and argument array)
  -> policy re-read         (from the file, not the copy planning used)
  -> execution              (ExecutionEngine, through ExecutionGuard)
  -> verification           (the owning provider, read-only)
  -> history                (attempt or skip, with the reason)
```

Each arrow is a place MacUp can stop, and stopping is the default. The
sections below explain the joints that are not obvious.

## The update pipeline

### Policy is asked twice

The planner asks `PolicyEngine` before it builds a plan, and the execution
engine asks again immediately before it runs one. The second read is the
decisive one, and it comes from the configuration *file* rather than from the
copy the plan was built with.

Planning-time policy is not enough because a plan can be minutes old. A user
who excluded a package after reviewing the list — or a scheduled run whose
plan was written before the user changed a rule — should get the rule they
have now, not the rule they had then (CLAUDE.md §2.20). The engine also
re-checks the confirmation requirement at that point: a decision of `confirm`
runs only for an item the caller listed as confirmed, and only when the run
is interactive, so an unattended run cannot inherit a confirmation nobody
gave.

### Two allowlists

There are two, because a check and an update are bounded differently.

`CommandAllowlist.readOnlyCheck` bounds what a **check** may run. Its rules
(`CommandRule`) permit a fixed executable name, a fixed leading verb, and a
closed set of options — and *no positional arguments at all*. A check never
names a package, so a rule that forbids positionals is exactly right, and it
is what makes a read-only command structurally unable to act on something.
`ReadOnlyCommandGuard` enforces it.

One read-only question does have to name an item: what depends on it
(`brew uses --installed`). Its rules live apart, in
`CommandAllowlist.dependentsLookup`, and take exactly one positional,
checked like a modifying command's. Only `DependentsLookup` adds them to
the check's rules, when someone asks about that item; `CheckEngine` never
does, so a check still cannot name anything.

`ModifyingCommandRules.all` bounds what an **update** may run. A modifying
command has to name the thing it changes, so `ModifyingCommandRule` allows
positional arguments — and then checks them rather than trusting them. A
positional may not start with `-` (a provider could read it as an option),
may not carry control or bidirectional-override characters (a person reading
the plan would not see what MacUp is about to run), and the count is **exact
rather than an upper bound**. The count matters in the direction people do
not expect: naming too few arguments is the dangerous case. `npm install -g`
with no package installs the working directory as a global package, and `brew
upgrade` with no formula upgrades everything, walking straight past every
exclusion.

`ExecutionGuard` adds a third condition on top of the second list: the
command must appear in **the plan the user reviewed**, matched by executable
path, argument array, *and* effect. Matching the effect too means a command
the plan presented as a change cannot be slipped past labelled read-only, or
the other way round; either would make the plan a poor description of what
happened. A guard is built per plan and lives only for that plan's run.

So a modifying command has to clear both gates: it has to be a shape MacUp
has reviewed, and it has to be in this plan. Being listed in a plan is not by
itself permission to run a shape of command nobody vetted, and being a vetted
shape is not permission to run it on an item the user did not see. Anything
else is refused before it reaches the operating system, and the refusal names
the command.

Verification is given a guard with **no** modifying rules at all, plus part
of the read-only check allowlist on top of the plan's own verification
commands — because a provider usually has to locate itself again before it
can read a version back, and those lookups were not part of the change the
user reviewed.

Only part of it: the rules are filtered to effect `readOnly`, so the
metadata-refresh rule is excluded. `brew update` is on the check allowlist
because `macup check --refresh` needs it, and without the filter a provider
could reach it while reading a version back. Refreshing Homebrew's metadata
changes no installed package, so this is not about damage — it is that the
plan is meant to be a complete description of what happens, and an update the
user reviewed never said it would refresh anything.

### Why the provider supplies the environment

An `ExecutionStep` carries the exact executable and argument array. That is
what a person reviews, and it is deliberately all it carries. But it is only
half of what a plan promises, because some guarantees have no command-line
flag and exist only in the environment.

Homebrew is the case that forced this. `HOMEBREW_NO_INSTALL_CLEANUP` is the
only way to stop Homebrew running `brew cleanup` after an upgrade, which
MacUp never does on its own (CLAUDE.md §2.16, §2.17), and
`HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK` is the only way to stop Homebrew
upgrading installed dependents of the named item — packages the user never
reviewed and may have excluded. Run the same argument array without those two
variables and the plan is broken, silently.

So the execution engine does not assemble an environment. It locates the
provider first, through a runner that allows nothing but the read-only
allowlist, and then asks that provider what its own commands need
(`executionEnvironment(context:)`). Detection happens once per provider per
run and its result is reused for verification, so the version MacUp reads
back comes from the installation it just changed. A provider MacUp cannot
find — or does not have loaded at all — means the plan does not run: without
one there is nothing to say what the command needs and nothing to confirm the
result.

Steps run with the **home directory** as the working directory, never the
directory MacUp happened to be started in, so a tool that reads
project-local configuration cannot pick up whichever project the user's shell
was sitting in.

### Failure and cancellation

A failed step ends that item; nothing after it runs, because the later steps
were written assuming the earlier ones worked. A failure anywhere in the run
also ends the run's appetite for `high` and `unknown` risk changes: after a
failure MacUp no longer knows the state of the machine as well as it did when
the plan was written, so the changes that would be hardest to unpick are
skipped with that reason. Cancellation reaches the running child process and
stops the loop before the next item.

## Concurrency

Use structured concurrency for independent read-only checks.

Modification is different: items run strictly one at a time, never
overlapped. Two package managers rewriting the same machine at once is not
something MacUp could reason about afterwards, let alone explain, so the
execution engine does not attempt it — not as a tuning decision that could be
relaxed later, but because the resulting history would not be a truthful
account of what happened.

Use actors where shared mutable state exists:
- history writer
- in-memory provider status store
- execution coordinator if needed

No unbounded task creation.

## Binary resolution

Do not blindly trust GUI PATH.

Resolve provider binaries using (docs/COMMAND_EXECUTION.md has the details):
1. configured explicit path if valid — and nothing else when one is set
2. the user's `PATH` (the CLI's own; for the GUI, discovered from the login shell)
3. standard package-manager locations, only when root or the user controls them

Record and display the chosen path.

If conflicting installations are found, Doctor reports them.

## Configuration

Config is versioned and atomically written. One canonical scheme, shared by
the CLI and the app, documented in `docs/CONFIGURATION.md`:

- configuration: `~/.config/macup/config.json`
- state (history, saved check results): `~/.local/state/macup/`

`XDG_CONFIG_HOME` and friends are deliberately not honored, because an app
launched from Finder does not see shell variables and the two surfaces would
then read different policies. Changing a policy goes through `PolicyEditor`
for the same reason.

Before public release, align with macOS conventions while keeping CLI behavior intuitive.

## Error model

Do not reduce everything to strings.

Create typed categories:
- providerUnavailable
- commandFailed
- parseFailed
- policyDenied
- authorizationRequired
- timeout
- cancelled
- verificationFailed
- ambiguousOwnership
- unsupported
- configurationInvalid

Attach display-safe details separately.

## Version comparison

Do not assume SemVer.

Implement:
- semantic comparison when parseable and appropriate
- provider-supplied comparison/metadata when available
- opaque current/target strings otherwise

Risk logic must tolerate opaque versions.
