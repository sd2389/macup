# Test Plan

## The golden rule

> A passing test suite must not alter the host development environment.

Everything below follows from that. It is not a style preference: a project
whose selling point is that it will not change your Mac without telling you
cannot have a test suite that changes your Mac.

## Where the suite stands

`scripts/test.sh` runs roughly 600 tests across three targets. At the time of
writing, 599:

| Target | Tests | What it covers |
| --- | --- | --- |
| `MacUpCoreTests` | 516 | Models, configuration, providers and parsers, policy, planning, execution, history, Doctor, utilities, and stub-executable integration |
| `MacUpCLITests` | 44 | Argument parsing, human and JSON output, exit codes |
| `MacUpAppTests` | 39 | The app's model: status, counts, schedule and security changes, host isolation |

The counts move with every change, so treat them as a scale rather than a
promise. `scripts/test.sh --filter <name>` runs a subset.

## What is deliberately not tested

This is the more useful half of the document.

**No test runs a modifying provider command.** Not against a real tool, not
against a stub that pretends to be one and then does something. `brew
upgrade`, `npm install -g`, and `mise upgrade` are never executed by the
suite in any form. The execution engine is exercised against a scripted
provider and a fake command runner, so the plans it carries out exist only
inside the test, and the "commands" it runs are recorded rather than
launched.

**No test runs a real provider binary at all**, modifying or otherwise.
`FakeCommandRunner` throws on any command a test did not register, so a test
that accidentally reached for `brew` fails loudly instead of quietly using
the developer's Homebrew.

**No test touches the real configuration or state directories.**
`MACUP_CONFIG_DIR` and `MACUP_STATE_DIR` point into temporary directories.

**No test installs a launchd agent**, opens a camera, or shows an
authentication prompt. `Tests/MacUpAppTests/HostIsolationTests.swift`
asserts all of that directly rather than leaving it to reviewer discipline.

**No test measures performance**, and the suite publishes no benchmark
numbers. There are none to publish.

**Face-matching accuracy is not tested against real faces.** Vision's
feature prints were built for image similarity rather than identity, so the
default threshold is a starting point, not a tuned value. This is recorded
in `docs/IMPLEMENTATION_CHECKLIST.md` as an open limitation.

The only real processes the suite launches are harmless system tools
(`printf`, `echo`, `env`, `sleep`, `dd`, `pwd`, `cat`) and throwaway stub
scripts it writes into a temporary directory, used to prove that
`ProcessCommandRunner` itself behaves. Standard provider locations are
overridden in those tests so the real tools can never be picked up.

## Unit tests

### Policy
- item override beats provider; provider beats global
- `ignore` and `pin` keep an item out of any plan
- `ask` is never silently scheduled: an unattended run denies it
- `auto` is allowed only under the applicable risk rules
- unknown risk becomes a confirmation
- a macOS item always asks, whatever the configuration says
- a runtime major change, an administrator prompt, a restart, and a config
  or lockfile rewrite each escalate an `auto` item
- `confirmMajorUpdates` governs only an ordinary package's major bump and
  cannot buy past the rules above it
- a configuration MacUp could not read denies everything
- a disabled provider denies everything
- a provider-pinned item denies everything
- every decision carries a reason naming the item

### Policy editing
- an invalid package ID is refused before the file is opened
- a configuration with errors is never rewritten
- an unknown key survives, because the file is left alone
- an edit whose result would be invalid is refused before writing
  (`pin` on a provider, `pin` or `inherit` as the global default)
- a no-op edit writes nothing and says so
- clearing a rule that was not set reports that there was nothing to clear
- a listing resolves inheritance through the engine, so it cannot disagree
  with the decision the user will get
- an item key that will not parse is reported, not dropped

### Command runner
- arguments remain separate
- package strings cannot inject shell syntax
- timeout
- cancellation
- stdout/stderr
- non-zero exit
- environment override
- executable not found
- log redaction

### Command rules and guards
- the read-only allowlist permits no positional arguments at all
- a modifying rule refuses a positional that starts with `-`, that carries
  control or bidirectional-override characters, or that is padded
- a rule's positional count is exact, so a command naming too few arguments
  does not match
- `ExecutionGuard` refuses a change that is not in the plan
- `ExecutionGuard` refuses a change that is in the plan but matches no
  reviewed rule
- effect is matched too, so a command cannot be relabelled to slip through
- verification is given no modifying rules, and no metadata-refresh rule

### Homebrew parser
Fixtures:
- formula updates
- cask updates
- both
- none
- pinned
- malformed JSON
- schema additions
- Unicode names/descriptions
- failure
- installed versions read back after an upgrade

### npm parser
Fixtures:
- scoped packages
- multiple packages
- none
- non-zero + valid JSON
- malformed output
- permission error
- npm itself
- package current newer than registry latest
- global tree read back after an install

### mise parser
Fixtures:
- exact pin
- fuzzy major
- multiple tools
- inactive
- local/global distinction
- malformed JSON
- tool list read back after an upgrade

### macOS parser
Fixtures for supported `softwareupdate` output forms.
Parsing ambiguity must produce an error/finding rather than fabricated state.

### Planning
- the exact executable and argument array, per provider
- planning runs no commands: the planner's runner is the read-only guard,
  and a provider that tried to run something is refused
- an excluded, pinned, or ignored item is absent from `planned` and present
  in `skipped` with its reason
- a provider with no `planUpdates` capability is refused by capability
- macOS refuses to plan, and says why
- mise refuses an exact pin, a project config, a system config, and a
  request it cannot attribute
- npm refuses a version position that is not plainly a version
- Homebrew refuses a pinned item and an ambiguous formula/cask namespace
- an item whose name MacUp cannot display exactly is refused
- no plan claims rollback

### Execution
- policy is re-read before each item, and the new answer wins
- a `confirm` decision runs only for a confirmed item, and only when
  interactive
- an unattended run refuses a plan that may need a password or a restart
- a dry run launches nothing and records nothing
- items never overlap
- a failed step ends that item
- a failure stops the run before later high-risk and unknown-risk items
- cancellation stops the run and is reported as cancelled
- a plan with no steps, or a step without a usable time limit, is refused
- the environment comes from the owning provider, not the engine
- a provider MacUp cannot find means the plan does not run

### Verification
- target reached
- target not reached (reported as such, never as success)
- command succeeded but verification failed
- output that could not be parsed
- item no longer listed by the provider

### History
- every attempt and every skip is recorded, with the reason
- a dry run records nothing
- redaction is applied by the store as well as by the engine
- an entry containing a line break is refused rather than split
- an undecodable line is counted and reported, never guessed at
- trimming keeps the newest entries and replaces the file atomically
- the file is owner-only, a regular file MacUp owns, and never followed
  through a symlink

### Doctor
- each of the eleven checks, driven from a synthetic provider report
- findings are ordered deterministically and de-duplicated
- a check that covers ground a provider already reported stands down
- a missing provider is information, not a fault
- a directory another user can write is an error
- an architecture MacUp cannot interpret produces no finding
- a launchd state it could not read is reported as unknown
- no finding contains the value of an environment variable: a test plants
  `GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`, and `NODE_OPTIONS` and asserts it
- diagnosing a machine runs nothing against it, except reading the login
  shell, and every command it does run is read-only

## Integration tests

`Tests/MacUpCoreTests/Integration` runs the real `ProcessCommandRunner`
against stub executables generated in a temporary directory, with standard
locations overridden so the real tools can never be picked up. The stubs
print fixture output; none of them changes anything.

The complete path — check → candidate → policy → plan → execution →
verification → history — is exercised with a fake runner, so "execution"
means the engine's own logic rather than a subprocess.

## UI tests

The app's model is tested directly (`MacUpAppTests`): the glanceable status,
which must never say "up to date" after an incomplete, cancelled, or failed
check; the update and attention counts; an overlapping check being ignored;
a failed schedule change leaving a readable problem and no claim of success;
the schedule and security busy flags staying separate; what this Mac can be
asked for with and without the password fallback; and face enrolment being
cancellable.

Full view-level UI tests need Xcode. Until then, screens are reviewed by
rendering them: a debug build accepts `--snapshot-dir` and writes every
screen in light and dark mode to PNG files (`docs/DEVELOPMENT.md`).

## Security tests

Hostile item names — spaces, quotes, semicolons, `$()`, backticks,
newlines, Unicode, leading dashes — are passed through the parsers, the
planner, and the command rules. They are carried as single verbatim elements
of an argument array and never interpreted by a shell, which is what makes
the shell metacharacters inert. Names that a person could not read correctly
in a plan, or that a provider could mistake for an option, are refused rather
than passed on.

Also covered: redaction of every credential shape the redactor knows, the
home directory becoming `~` in displayed text, symlink and permission
handling for the config and history files, and refusing to run as root.

`scripts/check-trust-invariants.sh` is a static check rather than a test, and
CI runs it on every push: no shell invocation, no process launched outside
`ProcessCommandRunner`, no modifying provider verb outside the four files
reviewed to contain one, no `--bump` anywhere, and no system daemon.

## Release smoke test

On a clean test Mac:
- install
- launch
- CLI help
- check
- GUI check
- policy persistence
- dry run
- controlled update of a safe disposable test package
- history
- uninstall/remove scheduler

This is a manual checklist on a disposable machine, deliberately outside the
automated suite: it is the one place a real update is performed, and the
golden rule says that cannot happen anywhere `swift test` can reach.
