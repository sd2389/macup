# MACUP MASTER BUILD SPEC

This is the single-file authoritative build specification for MacUp.

**How to use with Claude Code**
1. Put this file at the repository root as `MACUP_MASTER_BUILD_SPEC.md`.
2. Tell Claude Code: **"Read MACUP_MASTER_BUILD_SPEC.md completely. Treat it as the authoritative product, architecture, security, UX, testing, and implementation specification. Start with Phase 0 and Phase 1 only."**
3. Do not let Claude run real update/upgrade commands during the read-only phase.
4. Review each completed phase before moving to the next.

---



---

# SOURCE FILE: `README.md`

# MacUp — Claude Code Build Kit

MacUp is a local-first, open-source macOS developer-environment manager.

Its job is to help a user **understand, review, update, and maintain** the package managers, runtimes, CLI tools, and developer applications on their Mac without blindly changing the machine.

## Working product statement

> One place to understand, update, and maintain your Mac development environment.

## North star

MacUp should be **conservative with changes and aggressive with information**.

A user must be able to see:
- what MacUp detected,
- who manages each item,
- what is outdated,
- what MacUp proposes to do,
- the exact command it intends to execute,
- whether the action requires privilege/restart/approval,
- what succeeded or failed,
- and how to prevent an item from being touched again.

MacUp must never silently change something the user did not authorize.

## First release

v0.1 is intentionally narrow:
- Swift core
- Swift CLI
- SwiftUI desktop app
- Homebrew formulae + casks
- npm global packages
- mise-managed runtimes
- macOS software-update detection
- persistent package/provider policies
- read-only check mode
- dry-run plan
- explicit per-item updates
- update history
- basic Doctor
- no cloud
- no account
- no telemetry by default
- no arbitrary remote commands

Read `CLAUDE.md` first. It is the authoritative implementation brief.


---

# SOURCE FILE: `CLAUDE.md`

# CLAUDE.md — MacUp authoritative build instructions

## 0. Mission

Build **MacUp**, an open-source native macOS utility and CLI that gives users one trustworthy place to understand, review, update, and maintain their developer environment.

MacUp is not a new package manager. It is an orchestration, policy, diagnostics, and UX layer over package managers already installed on the Mac.

Working product statement:

> One place to understand, update, and maintain your Mac development environment.

Primary user:
- software developers and technical Mac users
- users with multiple update ecosystems such as Homebrew, npm, mise, Python tooling, Cargo, apps, and macOS updates
- people who care about control and do not want a black-box “update everything” button

## 1. Non-negotiable product principle

**MacUp must be conservative with changes and aggressive with information.**

Never guess when executing.

If MacUp cannot confidently determine:
- who owns an item,
- the exact command required,
- whether a policy allows the change,
- or whether the command can be performed safely,

then do **not** modify the item. Report the ambiguity to the user.

## 2. Trust contract — hard requirements

These are product requirements, not suggestions.

1. Read-only commands do not install, upgrade, remove, clean, prune, or rewrite user configuration.
2. Every modifying action must be attributable to a user action or a previously saved explicit policy.
3. Before modification, MacUp must be able to show an execution plan.
4. The execution plan must include the exact executable and arguments MacUp intends to invoke.
5. Never construct shell commands by concatenating untrusted strings.
6. Use `Process`/argument arrays, never `sh -c` for normal provider execution.
7. Never pipe remote content into a shell.
8. Never run the whole application as root.
9. Never store or capture administrator passwords.
10. Never hide privilege escalation.
11. No arbitrary remote command execution.
12. No remote kill switch.
13. No silent telemetry.
14. No account or cloud dependency in v1.
15. Local environment inventory remains local by default.
16. No automatic destructive cleanup.
17. No automatic `brew cleanup`.
18. No automatic runtime major-version bumps.
19. No automatic macOS installation/restart in v1.
20. User exclusions and policies must be checked immediately before execution, not only when the update list is first generated.
21. Update history must record what MacUp attempted and the result.
22. Never claim rollback is available unless the specific provider/action has an implemented and tested rollback strategy.
23. Fail closed: ambiguity means skip + explain, not guess + execute.
24. Tests must never upgrade the developer's real machine.
25. Provider parsers must be tested with fixture output.

See `docs/TRUST_AND_SECURITY.md`.

## 3. Product scope

### v0.1 must support

Providers:
- Homebrew formulae
- Homebrew casks
- npm global packages
- mise-managed runtimes
- macOS software update **detection only**

Capabilities:
- provider detection
- installed-item inventory
- outdated-item detection
- ownership display
- update plan generation
- dry run
- update selected items
- update all **allowed** items
- provider-level policy
- per-item policy
- exclusions
- Ask First policy
- Auto Update policy
- Ignore policy
- Pin model where safely supported
- update history
- cancellation where possible
- post-update verification
- basic Doctor diagnostics
- local scheduling architecture using launchd
- menu-bar desktop experience
- clear logs
- exportable diagnostics with secrets redacted

### Explicitly out of scope for v0.1

Do not expand scope without completing and testing v0.1:
- cloud backend
- accounts/login
- teams/fleet management
- remote execution
- billing
- AI assistant
- vulnerability scanner
- full rollback engine
- app-store update installation
- pip/uv/cargo/gem providers
- auto-fixing shell dotfiles
- uninstall/cleanup functionality
- system “optimizer” features
- antivirus
- background root daemon

## 4. Tech stack

Use:
- Swift
- SwiftUI
- Swift Package Manager
- Swift Argument Parser for CLI
- Foundation `Process` for subprocesses
- Swift Concurrency (`async/await`, task groups/actors where appropriate)
- OSLog
- JSON for v0.1 configuration
- JSONL or SQLite for history; prefer JSONL first unless SQLite clearly simplifies correctness
- launchd for scheduling
- Swift Testing where practical; XCTest is acceptable where needed
- GitHub Actions
- Apple Developer ID signing/notarization for release builds
- Sparkle only later for app self-update; do not make v0.1 dependent on it

Minimum target:
- macOS 14+

Architectures:
- arm64 required
- x86_64 supported where dependencies and CI permit
- design release flow for universal binaries, but do not compromise v0.1 correctness to achieve universal packaging

## 5. Repository architecture

Use one repository.

Preferred layout:

```text
MacUp/
├── CLAUDE.md
├── README.md
├── LICENSE
├── SECURITY.md
├── CONTRIBUTING.md
├── Package.swift
├── Sources/
│   ├── MacUpCore/
│   │   ├── Models/
│   │   ├── Providers/
│   │   │   ├── Homebrew/
│   │   │   ├── Npm/
│   │   │   ├── Mise/
│   │   │   └── MacOS/
│   │   ├── Policy/
│   │   ├── Planning/
│   │   ├── Execution/
│   │   ├── Diagnostics/
│   │   ├── History/
│   │   ├── Configuration/
│   │   ├── Scheduling/
│   │   └── Utilities/
│   └── macup/
│       ├── Commands/
│       └── main.swift
├── Apps/
│   └── MacUpApp/
│       ├── MacUpApp.xcodeproj
│       └── MacUpApp/
│           ├── App/
│           ├── Features/
│           │   ├── Dashboard/
│           │   ├── Updates/
│           │   ├── Doctor/
│           │   ├── History/
│           │   └── Settings/
│           ├── Components/
│           └── Resources/
├── Tests/
│   ├── MacUpCoreTests/
│   │   ├── Providers/
│   │   ├── Policy/
│   │   ├── Planning/
│   │   ├── Execution/
│   │   ├── Diagnostics/
│   │   └── Fixtures/
│   └── MacUpCLITests/
├── docs/
└── scripts/
```

The SwiftUI app and CLI must both use `MacUpCore`. Do not duplicate provider or policy logic in the UI.

## 6. Core domain model

Design stable domain models before provider code.

At minimum define concepts equivalent to:

```swift
ProviderID
PackageID
ManagedItem
InstalledVersion
AvailableVersion
UpdateCandidate
UpdateRisk
UpdatePolicy
ExecutionPlan
ExecutionStep
ExecutionResult
VerificationResult
ProviderCapability
ProviderStatus
DiagnosticFinding
HistoryEntry
```

Use strong typed IDs where useful instead of passing raw strings everywhere.

A package identity must include its provider. Example:
- `brew:git`
- `brew-cask:visual-studio-code`
- `npm:@anthropic-ai/claude-code`
- `mise:node`
- `macos:26.6.2`

Do not assume names are globally unique.

### Update policy

Support:

```text
auto
ask
ignore
pin
inherit
```

Inheritance:
1. per-item rule
2. provider rule
3. global default

Recommended default:
- manual use: `ask`
- scheduled background maintenance: only items explicitly `auto`
- macOS: always `ask` in v1
- runtime major changes: always `ask`
- unknown risk: always `ask`

A policy decision must return both:
- decision
- human-readable reason

## 7. Provider protocol

Providers should expose capabilities instead of being treated identically.

Conceptually:

```swift
protocol UpdateProvider {
    var id: ProviderID { get }
    var displayName: String { get }
    var capabilities: Set<ProviderCapability> { get }

    func detect(context: ProviderContext) async -> ProviderStatus
    func inventory(context: ProviderContext) async throws -> [ManagedItem]
    func outdated(context: ProviderContext) async throws -> [UpdateCandidate]
    func makePlan(
        for candidate: UpdateCandidate,
        context: ProviderContext
    ) async throws -> ExecutionPlan
    func verify(
        _ result: ExecutionResult,
        for candidate: UpdateCandidate,
        context: ProviderContext
    ) async throws -> VerificationResult
}
```

Modification should be executed by a centralized execution engine after policy evaluation; providers should not silently execute while “checking”.

## 8. Command execution layer

Build one hardened `CommandRunner`.

Requirements:
- executable path + argument array
- environment allowlist/overrides
- working directory support
- timeout
- cancellation
- stdout/stderr capture
- streaming output option for UI
- exit status
- start/end timestamps
- no shell interpolation
- redact secrets in logs
- testable through a protocol/mock
- resolve binaries intentionally

Store a display-safe command representation separately from the actual argument array.

Example actual execution:
```text
executable: /opt/homebrew/bin/brew
arguments: ["upgrade", "git"]
```

Never:
```text
"/bin/zsh -c 'brew upgrade \(userInput)'"
```

## 9. Provider implementation requirements

### Homebrew

Detection:
- resolve `brew` from PATH and common Apple Silicon/Intel locations
- record the exact binary path being used
- report multiple detected installations as a Doctor finding

Read-only outdated check:
- use stable CLI JSON output where available
- prefer `brew outdated --json=v2`
- avoid relying on Homebrew private Ruby APIs
- do not call blanket `brew upgrade`

Important:
- MacUp exclusions require per-item upgrades.
- Formula: `brew upgrade <formula>`
- Cask: use provider-appropriate cask upgrade invocation.
- Do not run `brew cleanup` automatically.
- Do not silently unpin Homebrew-pinned formulae.
- Detect Homebrew pin state and reflect it in MacUp.
- Respect `HOMEBREW_NO_AUTO_UPDATE` semantics.
- Distinguish “refresh package metadata” from “read current local metadata”.
- A normal `macup check` must not unexpectedly upgrade Homebrew or packages.

Tests:
- formula outdated fixture
- cask outdated fixture
- no updates
- pinned item
- malformed JSON
- brew absent
- two brew installs
- failed command
- package names with unusual but valid characters

### npm global provider

Scope:
- global packages only in v0.1
- do not scan every project on disk

Requirements:
- determine the exact `node`, `npm`, npm prefix, and environment used
- ownership matters because global packages can be tied to a mise-managed Node installation
- inventory via npm JSON output
- outdated via npm JSON output
- handle npm commands whose non-zero exit status can still contain valid “outdated” data
- parse scoped names correctly
- never interpolate package names into a shell string
- update one selected package at a time so exclusions remain enforceable
- verify version after update
- surface when updating npm itself requires special handling
- warn if changing the active Node runtime would change the global npm package universe

Tests:
- scoped packages
- empty output
- outdated packages
- package newer than latest
- malformed JSON
- npm absent
- npm under mise
- exit code + valid JSON
- permissions failure

### mise provider

Requirements:
- detect exact mise binary and version
- use JSON output for outdated checks
- by default preserve the version request/range rather than bumping major versions
- do not use `--bump` automatically
- support provider plans that make clear whether config files or lockfiles may change
- avoid pruning old runtimes automatically in v0.1
- major/runtime changes are Ask First
- local project configs must not be silently rewritten from a global maintenance run

Recommended model:
- global mise configuration is managed separately from project-local configurations
- v0.1 automatic maintenance should prefer global config only
- discovering a project-local outdated runtime can be informational unless the user explicitly targets that project

Tests:
- node/python global config
- exact pin
- fuzzy version
- no updates
- JSON malformed
- inactive tools
- local config present
- lockfile impact
- dry-run output
- mise absent

### macOS provider

v0.1:
- detection/listing only
- parse `softwareupdate` output behind an abstraction
- no automatic install
- no automatic restart
- no hidden sudo
- show restart requirement if discoverable
- treat parsing uncertainty as a diagnostic, not permission to guess

macOS upgrades remain `ask` and informational until installation behavior has its own security review and tests.

## 10. Update risk model

Risk is not marketing language. It drives policy.

Suggested levels:
- low
- moderate
- high
- unknown

Signals:
- patch vs minor vs major when semantic versions are meaningful
- runtime/toolchain change
- OS change
- restart required
- admin authorization required
- provider cannot guarantee target version
- provider action may rewrite config
- provider action may affect multiple dependents
- package is pinned
- package manager itself is being updated

Unknown risk => Ask First.

Do not pretend all version strings are SemVer.

## 11. Execution planning

Every update runs through:

```text
candidate
  -> current policy
  -> risk assessment
  -> execution plan
  -> final policy re-check
  -> execution
  -> verification
  -> history
```

An `ExecutionPlan` must contain:
- item
- current version
- proposed version
- provider
- risk
- reason/rationale
- exact executable path
- exact argument list
- whether network is expected
- whether privilege may be required
- whether restart may be required
- whether user config may change
- verification steps
- rollback capability: true/false/unknown, with explanation

Never label an operation “safe” merely because it is common.

## 12. CLI contract

Required commands:

```bash
macup
macup check
macup check --refresh
macup update
macup update <package-id>...
macup update --dry-run
macup plan
macup doctor
macup history
macup config show
macup config path
macup provider list
macup provider enable <provider>
macup provider disable <provider>
macup policy list
macup policy set <package-id> <auto|ask|ignore|pin>
macup policy clear <package-id>
```

Aliases such as `exclude` may map to `policy set ... ignore`, but there should be one policy source of truth.

Examples:

```bash
macup policy set npm:@anthropic-ai/claude-code ask
macup policy set brew:postgresql ignore
macup provider disable mise
macup update brew:git
macup update --dry-run
```

CLI requirements:
- useful exit codes
- human output by default
- `--json` for automation where practical
- no ANSI when not a TTY
- stable machine-readable schemas should be versioned
- destructive/modifying commands clearly distinguished
- Ctrl+C cancellation should be handled cleanly

Default `macup` should behave like a read-only status/check command, not modify the machine.

## 13. Desktop app

Native SwiftUI.

Primary navigation:
- Dashboard
- Updates
- Doctor
- History
- Settings

Also provide a MenuBarExtra experience.

### Dashboard

Show:
- overall status
- update count
- providers found
- providers with errors
- ignored/pinned count
- last check
- next scheduled check if scheduling enabled
- clear “Review Updates” primary action

Avoid fake health percentages in v1 unless there is a defensible formula.

### Updates

Group by provider.

Each item shows:
- name
- current -> available
- provider
- policy
- risk
- reason
- optional release/source metadata when available

Controls:
- Update
- Ask First
- Auto Update
- Ignore
- Pin (only when capability supports it)
- View command/details

Bulk actions must operate on a generated plan and obey individual policy.

### Execution review sheet

Before a meaningful batch:
- number of changes
- ignored items
- items requiring confirmation
- commands
- risk/restart/admin/config-change indicators

### Doctor

Start with deterministic diagnostics, not AI:
- multiple Homebrew installations
- provider binary not found
- PATH discrepancy between GUI and shell
- multiple Python/Node ownership hints
- npm prefix mismatch
- mise-managed Node + different npm binary
- inaccessible config/history directory
- stale/invalid configuration
- provider parser failure
- binary architecture mismatch if discoverable

Doctor should explain, not automatically “fix everything”.

### History

Record:
- timestamp
- item/provider
- before/target/after versions
- command display
- result
- verification
- error summary
- duration
- execution origin: CLI/manual GUI/scheduled

### Settings

Sections:
- General
- Providers
- Update policies
- Scheduling
- Privacy
- Diagnostics

Telemetry:
- absent or OFF by default
- no dark patterns

## 14. Configuration

Default:
`~/.config/macup/config.json`

Use an explicit schema version.

Example:

```json
{
  "schemaVersion": 1,
  "global": {
    "defaultPolicy": "ask",
    "confirmMajorUpdates": true
  },
  "providers": {
    "homebrew": { "enabled": true, "policy": "ask" },
    "npm": { "enabled": true, "policy": "ask" },
    "mise": { "enabled": true, "policy": "ask" },
    "macos": { "enabled": true, "policy": "ask" }
  },
  "items": {
    "npm:@anthropic-ai/claude-code": { "policy": "ask" },
    "brew:postgresql": { "policy": "ignore" }
  },
  "schedule": {
    "enabled": false,
    "frequency": "daily",
    "time": "23:00"
  },
  "privacy": {
    "telemetry": false
  }
}
```

Requirements:
- atomic writes
- backup before migration
- schema migrations
- validation
- corrupted config must not result in permissive defaults for automatic modification
- config parse failure => disable automatic modifications + explain

## 15. Scheduling

Use launchd.

Important behavior:
- scheduled checks can be read-only by default
- scheduled updates may update only items explicitly marked `auto`
- `ask` items become notifications/review items, never silently updated
- `ignore` items remain untouched
- failure must be logged
- do not create a privileged always-running daemon
- scheduler configuration should be visible/removable by the user

Initial scheduling interface:
- Off
- Daily
- Weekly
- time
- notify when review is required

## 16. History and auditability

History is a trust feature.

Record every modification attempt and relevant skipped reason.

Do not log:
- passwords
- access tokens
- auth headers
- secrets from environment variables

Provide:
```bash
macup history
macup history --json
```

Provide an “Export Diagnostics” feature with explicit redaction.

## 17. Logging

Use OSLog internally plus a user-readable structured history.

Categories:
- core
- discovery
- policy
- planning
- execution
- homebrew
- npm
- mise
- macos
- doctor
- scheduler

Verbose/debug output must be opt-in.

Never dump complete environment variables into logs.

## 18. Privacy

v1 should work fully offline except where underlying package managers themselves require the network.

MacUp itself should not require:
- account
- cloud API
- analytics endpoint

If telemetry is added later:
- explicit opt-in
- documented event list
- no package inventory unless separately and explicitly opted into
- never send shell history, paths containing usernames where avoidable, project names, tokens, or file contents

## 19. Security requirements

Before v1 release:
- threat model documented
- command injection tests
- malicious/strange package-name fixtures
- symlink/path tests for config/history writes
- config file permission review
- PATH hijacking considerations documented
- executable resolution rules documented
- provider output treated as untrusted input
- release signing
- notarization
- checksums
- dependency review
- no curl-pipe-shell installer as the primary path
- security contact/process in SECURITY.md

## 20. Testing strategy

No real upgrades in unit/integration tests.

Use a `CommandRunning` protocol and fixtures.

Required test classes:
- model encoding/decoding
- config migration/validation
- policy precedence
- policy re-check before execution
- command argument safety
- output parser fixtures
- provider absence
- provider failure
- timeout/cancellation
- execution plan generation
- verification
- history redaction
- Doctor findings
- CLI JSON schema
- GUI view-model tests where practical

Golden rule:
> A passing test suite must not alter the host development environment.

For end-to-end tests, use disposable CI/macOS environments and mock/stub provider binaries where possible.

## 21. Accessibility and UX quality

Requirements:
- keyboard navigation
- VoiceOver labels
- sufficient contrast
- Dynamic Type where applicable
- no essential information conveyed by color alone
- clear error copy
- “Update All” must never obscure ignored/ask-first decisions
- no scary language for normal conditions
- no fake precision in risk/health scores

MacUp should look native, restrained, and professional — not like a web dashboard wrapped in a Mac window.

Use standard macOS conventions before custom visuals.

## 22. Open-source project quality

License target:
- Apache-2.0 unless owner changes decision before public release

Must include:
- README
- LICENSE
- SECURITY.md
- CONTRIBUTING.md
- CODE_OF_CONDUCT.md
- architecture docs
- issue templates
- pull request template
- changelog/release notes
- screenshots once UI exists

Public repo should be recruiter-quality:
- clean commit history
- understandable architecture
- meaningful tests
- visible CI
- tagged releases
- high-quality issues
- roadmap
- no generated junk committed
- no secrets
- no personal machine paths in fixtures

## 23. CI/CD

Pull requests:
1. swift format/lint if configured
2. build
3. unit tests
4. CLI tests
5. security/static checks practical for Swift
6. artifact smoke build

Release:
1. tag
2. clean build
3. tests
4. build CLI
5. build app
6. sign
7. notarize
8. produce DMG/zip as appropriate
9. generate SHA-256 checksums
10. GitHub Release
11. later: update Homebrew tap/cask

Do not commit signing secrets.

## 24. Development phases

### Phase 0 — repository foundation
Deliver:
- Swift package
- MacUpCore target
- `macup` executable
- tests
- docs
- CI
- config paths
- command-runner abstraction

Exit criteria:
- builds cleanly
- tests run
- `macup --help`
- no provider modifications yet

### Phase 1 — read-only engine
Deliver:
- Homebrew detection + outdated parsing
- npm global detection + outdated parsing
- mise detection + outdated parsing
- macOS update detection
- unified candidate model
- concurrent checks
- CLI status/check/json output

Exit criteria:
- `macup check` modifies no packages
- fixtures cover parsers
- absent providers handled cleanly

### Phase 2 — policy + planning
Deliver:
- policy store
- provider enable/disable
- item policies
- ignore/ask/auto/pin model
- dry-run planner
- exact command rendering

Exit criteria:
- `macup update --dry-run` executes nothing
- ignored items cannot enter executable plan
- policy precedence fully tested

### Phase 3 — safe execution
Deliver:
- Homebrew selected-item update
- npm selected-item update
- mise safe-range update
- verification
- history
- cancellation
- error handling

Exit criteria:
- no blanket provider upgrade where exclusions can be bypassed
- policy rechecked immediately before execution
- failures do not silently continue through high-risk changes

### Phase 4 — Doctor
Deliver deterministic diagnostics and CLI UI.

### Phase 5 — SwiftUI desktop
Deliver:
- Dashboard
- Updates
- Review plan
- Doctor
- History
- Settings
- MenuBarExtra

The GUI uses MacUpCore only.

### Phase 6 — launchd scheduling
Deliver:
- read-only scheduled check
- explicit-auto-only scheduled updates
- notifications
- schedule removal

### Phase 7 — release hardening
Deliver:
- security review
- accessibility review
- notarization/signing docs
- release packaging
- public docs
- beta

Do not jump to cloud/teams before v1 is stable.

## 25. Definition of Done for every modifying feature

A modifying feature is not done unless:
- there is a read-only discovery path
- there is a plan representation
- policy is enforced
- exact executable/args are known
- untrusted input is not shell interpolated
- dry-run works
- success is verified
- failure is surfaced
- history is recorded
- secrets are redacted
- tests cover success and failure
- docs explain behavior

## 26. Agent working rules

When implementing:
1. Inspect existing code before editing.
2. Preserve working behavior unless the spec intentionally changes it.
3. Make small coherent commits.
4. Do not rewrite large areas without need.
5. Do not invent provider commands; confirm with current official provider help/docs when uncertain.
6. Prefer machine-readable provider output.
7. Treat external command output as untrusted.
8. Add fixture tests before/with parsers.
9. Do not run modifying provider commands on the owner's machine as part of development unless explicitly asked.
10. It is acceptable to run read-only detection commands.
11. Never execute `brew upgrade`, `npm update -g`, `mise upgrade`, `softwareupdate --install`, cleanup/prune/uninstall commands during automated development/testing on the owner's machine.
12. Do not push/merge/release without the owner's explicit instruction.
13. Before each phase, write/update a short implementation checklist.
14. At the end of each phase, run tests and report:
   - files changed
   - tests
   - remaining risks
   - manual verification steps
15. If a trust/security requirement conflicts with convenience, trust/security wins.

## 27. Initial implementation request

Start with Phase 0 and Phase 1 only.

Do not attempt to build the entire product in one unreviewable change.

First:
1. inspect current repository
2. reconcile existing starter code with this spec
3. create/fix package structure
4. implement CommandRunner abstraction
5. implement domain models
6. implement configuration foundation
7. implement read-only Homebrew provider
8. implement read-only npm provider
9. implement read-only mise provider
10. implement read-only macOS provider
11. implement concurrent `macup check`
12. add fixture-heavy tests
13. add `--json`
14. run full test suite
15. produce a concise Phase 1 report

Absolutely no real upgrades during Phase 1.

Only after Phase 1 is green should you continue to Phase 2.


---

# SOURCE FILE: `BOOTSTRAP_PROMPT.md`

# First prompt to give Claude Code

You are implementing MacUp in this repository.

Treat `CLAUDE.md` as the authoritative specification and read all files in `docs/` before editing code.

Your first assignment is **Phase 0 + Phase 1 only**.

Do not perform real package upgrades on this machine.

Tasks:

1. Inspect the entire current repository and summarize what already exists.
2. Compare it against `CLAUDE.md`.
3. Preserve useful existing code; refactor only where required.
4. Establish the Swift package/core/CLI/test structure.
5. Implement a hardened, mockable command-runner abstraction.
6. Implement the initial domain models.
7. Implement versioned local configuration with atomic writes.
8. Implement read-only Homebrew provider using documented machine-readable output where possible.
9. Implement read-only npm global provider.
10. Implement read-only mise provider.
11. Implement macOS update detection only.
12. Implement concurrent unified `macup check`.
13. Implement `macup check --json`.
14. Add fixture-driven tests for every provider and parser.
15. Add tests proving hostile package names cannot become shell injection.
16. Add/update GitHub Actions CI.
17. Run the complete test suite.
18. Do not run `brew upgrade`, `npm update -g`, `mise upgrade`, `softwareupdate --install`, uninstall, cleanup, or prune commands.
19. Do not push, merge, tag, or release unless explicitly instructed.
20. Finish by reporting:
    - architecture created
    - files changed
    - commands/tests run
    - current test results
    - risks/unknowns
    - exact manual commands I can use to try the read-only CLI

When a provider command or output format is uncertain, verify it against current official documentation or the locally installed tool's `--help`; do not invent syntax.

Do not move on to modifying updates until Phase 1 is reviewed and green.


---

# SOURCE FILE: `docs/PRODUCT_SPEC.md`

# Product Specification

## Problem

A modern developer Mac can contain several independent update ecosystems. Users must remember:
- which package manager owns which tool,
- which command checks or upgrades it,
- which runtime a global tool belongs to,
- which updates are safe to automate,
- and which updates should be held back.

The result is fragmented maintenance and risky “update everything” scripts.

## Product

MacUp provides one trustworthy interface over those systems.

It answers:
1. What is installed?
2. Who manages it?
3. What is outdated?
4. What would change?
5. What is allowed to change?
6. What command will be run?
7. Did the update actually succeed?
8. What changed historically?
9. Is my developer environment misconfigured?

## Primary jobs to be done

### Understand
“Tell me what manages my tools and runtimes.”

### Review
“Show me what is outdated without changing anything.”

### Control
“Never update PostgreSQL automatically, always ask before Claude Code, and ignore mise.”

### Update
“Update only the items I approve.”

### Diagnose
“Why do I have multiple Node/Python/npm environments and which one am I using?”

### Maintain
“Check regularly and only auto-update things I explicitly permit.”

## Principles

- user control over convenience
- explanation before execution
- local first
- no hidden privilege
- provider-native actions
- fail closed
- open source
- native macOS UX
- useful without an account
- predictable over clever

## Personas

### Developer
Homebrew + mise + npm + Docker + editors/CLI tools.

### Power user
Many GUI apps and command-line tools; wants a consolidated update view.

### Team developer (future)
Needs machine consistency and policy, but this is not v1.

## MVP success criteria

A new user can install MacUp and within minutes:
- see detected providers,
- see outdated items,
- understand ownership,
- mark items Ask/Ignore/Auto,
- review exact commands,
- safely update selected items,
- inspect history,
- run Doctor,
- schedule checks.

## Metrics for later product validation

Do not add telemetry merely to collect these. Use opt-in methods, GitHub signals, or anonymous metrics only after a privacy design.

Potential measures:
- installs/releases downloaded
- GitHub stars
- repeat users
- update success rate
- provider parse-error rate
- issue volume by provider
- number of outside contributors
- percentage of users enabling scheduling (if explicitly measured)


---

# SOURCE FILE: `docs/ARCHITECTURE.md`

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

### CommandRunner
The only normal path for launching external executables.

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
select candidates
  -> generate plans
  -> present plan
  -> obtain/confirm authorization
  -> re-read policy
  -> execute sequentially or with conservative bounded concurrency
  -> verify
  -> record history
```

Avoid concurrent modifications by default. Checks may run concurrently; upgrades should start sequentially unless a provider is explicitly proven safe for parallel execution.

## Binary resolution

Do not blindly trust GUI PATH.

Resolve provider binaries using:
1. configured explicit path if valid
2. login-shell discovery strategy designed and tested for GUI context
3. standard package-manager locations
4. PATH

Record and display the chosen path.

If conflicting installations are found, Doctor reports them.

## Configuration

Config is versioned and atomically written.

Recommended directories:
- config: `~/.config/macup/`
- history/cache: appropriate Application Support or `~/.local/state/macup/` if CLI-first, but choose one canonical scheme and document it
- GUI must use the same source of truth as CLI

Before public release, align with macOS conventions while keeping CLI behavior intuitive.

## Concurrency

Use structured concurrency for independent read-only checks.

Use actors where shared mutable state exists:
- history writer
- in-memory provider status store
- execution coordinator if needed

No unbounded task creation.

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


---

# SOURCE FILE: `docs/TRUST_AND_SECURITY.md`

# Trust and Security

## Trust Contract

MacUp publicly commits to:

1. No hidden changes.
2. Read-only means no package/runtimes are modified.
3. Users can inspect a change before execution.
4. MacUp does not store admin passwords.
5. MacUp uses existing package managers instead of replacing them.
6. Saved exclusions/policies are enforced at execution time.
7. Major/unknown/high-risk changes require review.
8. Local inventory stays local by default.
9. Telemetry is off unless the user opts in.
10. Core behavior is open source.
11. Modification attempts are logged.
12. Rollback claims are capability-specific and truthful.
13. Ambiguity causes MacUp to stop/skip rather than guess.

## Threat model

Assets:
- user's developer environment
- executable search path
- package-manager configuration
- shell/runtime configuration
- credentials present in environment
- local filesystem
- administrator authorization
- trust in signed MacUp releases

Threats:
- command injection via package names/provider output
- PATH hijacking
- malicious or compromised upstream package
- parser confusion causing wrong target
- policy race/change between planning and execution
- accidental privilege escalation
- logging secrets
- corrupted configuration changing policy
- compromised update distribution
- symlink/path attacks on writable files
- malicious project-local config affecting global maintenance
- remote command capability introduced later

Mitigations:
- argument arrays, no shell interpolation
- explicit executable path
- provider output validation
- policy re-check before execute
- local-first
- atomic config
- strict file permissions where appropriate
- log redaction
- signed/notarized release
- checksums
- dependency minimization
- no root daemon
- no remote arbitrary command schema

## Privilege

The main process runs as the user.

When an operation legitimately needs authorization:
- explain why
- let macOS present standard authorization
- never collect the password in MacUp UI
- avoid custom privilege helpers until a separately reviewed need exists

## Remote architecture rule

If cloud/team functionality exists later, the server may express declarative desired state/policy, never arbitrary shell commands.

Allowed concept:
```json
{"tool":"node","policy":"pin","version":"24"}
```

Forbidden concept:
```json
{"command":"curl https://example | sudo sh"}
```

## Release security

Before public v1:
- Developer ID signature
- Apple notarization
- SHA-256 checksums
- GitHub protected release workflow
- documented build steps
- security reporting process
- dependency lock/review
- no secrets in repository or CI logs

## Incident principle

If MacUp causes or risks destructive behavior:
- stop release/update distribution if necessary
- disclose concrete scope
- provide remediation
- do not minimize impact
- add regression tests before restoring affected functionality


---

# SOURCE FILE: `docs/UX_SPEC.md`

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


---

# SOURCE FILE: `docs/PROVIDER_SPEC.md`

# Provider Specification

Providers are adapters, not independent mini-apps.

## Common provider rules

Each provider must:
- identify its binary
- report version/status
- inventory managed items where feasible
- return outdated candidates
- construct exact execution plans
- expose capabilities
- verify post-update state
- never bypass the central policy engine
- never silently update as part of `check`

## Homebrew

Read/check:
- prefer documented JSON CLI output
- `brew outdated --json=v2`
- distinguish formulae and casks

Update:
- one selected item at a time
- never blanket `brew upgrade` when policy exclusions exist
- no automatic cleanup
- preserve pins
- show when an action can update dependents

Provider ownership:
- record exact brew path
- report multiple installations

## npm global

Read/check:
- global only
- use JSON-capable npm commands
- record npm path, node path, prefix, versions
- parse scoped names

Update:
- selected package only
- exact argument array
- verify resulting installed version

Special:
- npm global packages depend on active Node/prefix
- ownership chain should be visible
- provider non-zero statuses with valid JSON must be handled according to documented behavior rather than treated as parse failure automatically

## mise

Read/check:
- use `mise outdated --json`
- preserve configured range by default
- separate global from local project configs

Update:
- no automatic `--bump`
- no automatic prune
- dry-run capability should be used to improve planning where useful
- explicitly show possible config/lockfile changes

Global maintenance:
- do not traverse and rewrite project configurations in v0.1

## macOS

v0.1 is informational:
- list available updates
- show version/title/restart indicators when parseable
- parser behind fixtures
- no install/restart

## Future providers

Candidates after v1:
- uv
- pipx
- Cargo
- RubyGems
- VS Code extensions
- App Store through an optional supported mechanism
- Docker Desktop/tooling
- GitHub CLI extensions

Do not add these until core contracts are stable.


---

# SOURCE FILE: `docs/TEST_PLAN.md`

# Test Plan

## Principle

Automated tests must not upgrade the host Mac.

## Unit tests

### Policy
- item override beats provider
- provider beats global
- ignore blocks plan
- ask cannot be silently scheduled
- auto allowed only under applicable risk rules
- unknown risk becomes ask
- corrupted config disables automatic modification

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

### mise parser
Fixtures:
- exact pin
- fuzzy major
- multiple tools
- inactive
- local/global distinction
- malformed JSON

### macOS parser
Fixtures for supported `softwareupdate` output forms.
Parsing ambiguity must produce an error/finding rather than fabricated state.

### Planning
- exact command details
- high/unknown risk
- excluded item absent
- pin behavior
- provider disabled
- plan stale/policy changed before execution

### Verification
- target reached
- target not reached
- command succeeded but verification failed
- executable disappeared

## Integration tests

Use fake provider binaries or temporary scripts returning fixture outputs.

Test complete:
check -> candidate -> policy -> plan -> mock execution -> verification -> history

## UI tests

Critical flows:
- first launch
- no providers
- updates available
- ignore item
- Ask First item
- plan review
- execution success
- partial failure
- Doctor finding
- scheduling settings

## Security tests

Try hostile item names:
- spaces
- quotes
- semicolon
- `$()`
- backticks
- newline
- Unicode
- leading dash

Confirm they are passed as arguments and never interpreted by a shell.

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


---

# SOURCE FILE: `docs/ROADMAP.md`

# Roadmap

## v0.0.1 — Foundation
- package structure
- core models
- command runner abstraction
- config
- tests
- CI

## v0.1.0 — Read-only Alpha
- Homebrew check
- npm global check
- mise check
- macOS update detection
- unified CLI
- `--json`
- no modification

## v0.2.0 — Policy + Planning
- Auto / Ask / Ignore / Pin / Inherit
- provider enable/disable
- dry-run
- execution plans
- exact command review

## v0.3.0 — Controlled Updates
- selected Homebrew updates
- selected npm global updates
- conservative mise updates
- verification
- history

## v0.4.0 — Doctor
- path/provider conflicts
- ownership chains
- config diagnostics

## v0.5.0 — Native App
- dashboard
- updates
- policy UI
- plan review
- doctor
- history
- settings
- menu bar

## v0.6.0 — Scheduling
- launchd
- scheduled check
- explicit-auto-only updating
- notifications

## v0.9.0 — Public Beta
- security review
- accessibility
- packaging
- crash hardening
- docs

## v1.0.0 — Stable
- signed/notarized release
- checksums
- stable config migration path
- documented machine-readable CLI schema

## Post-v1
Only after evidence of demand:
- uv/pipx/Cargo/etc.
- snapshots
- limited rollback strategies where technically sound
- environment export/restore
- cloud sync
- team policy
- fleet visibility

Cloud must never introduce arbitrary remote shell execution.


---

# SOURCE FILE: `docs/DECISIONS.md`

# Initial Architectural Decisions

## ADR-001 — Swift-native
Use Swift for Core, CLI, and native app to keep the product lightweight and deeply macOS-integrated.

## ADR-002 — MacUp is an orchestrator
MacUp does not replace Homebrew/npm/mise. It invokes provider-native tooling and adds discovery, policy, planning, verification, history, and UX.

## ADR-003 — Read-only default
The default command is non-modifying.

## ADR-004 — Central policy engine
Providers cannot bypass user policies.

## ADR-005 — No shell interpolation
External commands use executable + argument arrays.

## ADR-006 — Local first
No backend/account required for v1.

## ADR-007 — launchd
Scheduling uses macOS-native launchd, not cron as the product foundation.

## ADR-008 — No blanket upgrades
Where per-item policies/exclusions exist, execute selected items individually rather than calling an ecosystem-wide update-all command.

## ADR-009 — No universal rollback claim
Rollback is provider/action-specific.

## ADR-010 — Open source first
Core product is developed publicly; monetization can be decided after adoption.


---

# SOURCE FILE: `docs/RELEASE.md`

# Release and Distribution

## Development channels

- nightly/internal builds
- alpha
- beta
- stable

## CLI distribution

Initial:
- GitHub Releases

Then:
- Homebrew tap/formula

Desired user experience:
```bash
brew install <tap>/macup
macup check
```

## App distribution

Initial public:
- signed + notarized download from GitHub Releases/project site
- later Homebrew cask if appropriate

## Signing

Never commit certificates/private keys.

Use CI secrets and documented Apple notarization workflow.

## Artifacts

Release should include:
- CLI archive
- app/DMG or zip
- SHA256SUMS
- release notes
- provenance/signature metadata where practical

## Versioning

Semantic Versioning for MacUp releases.

Provider parsers are compatibility-sensitive; parser fixes can be patch releases unless behavior/API changes.

## Changelog

Maintain human-readable changes:
- Added
- Changed
- Fixed
- Security
- Provider compatibility

## Backward compatibility

Before v1:
- config migrations still required when schemas change

After v1:
- do not silently discard user policy during migration


---

# SOURCE FILE: `SECURITY.md`

# Security Policy

MacUp changes developer environments and therefore treats security and user control as core product requirements.

## Reporting

Before public launch, replace this section with a dedicated private security-reporting channel.

Do not encourage public disclosure of an unpatched vulnerability.

## Principles

- no arbitrary remote commands
- no hidden privilege escalation
- no shell interpolation of package/provider output
- least privilege
- local-first
- explicit policy enforcement
- signed/notarized releases
- secrets redacted from logs

See `docs/TRUST_AND_SECURITY.md`.


---

# SOURCE FILE: `CONTRIBUTING.md`

# Contributing

Thank you for contributing to MacUp.

## Before a PR

- read `CLAUDE.md`
- read `docs/TRUST_AND_SECURITY.md`
- add/update tests
- do not make provider checks mutate user packages
- do not add shell interpolation
- do not add telemetry or networking unrelated to provider behavior without design review

## Provider contributions

A new provider must include:
- detection
- read-only inventory/outdated behavior
- machine-readable parsing where possible
- fixture tests
- execution-plan design
- verification strategy
- capability declaration
- trust/security notes

Do not add a provider solely by invoking a blanket “upgrade everything” command.

## PR quality

Explain:
- problem
- approach
- trust/security impact
- tests
- manual verification


---

# SOURCE FILE: `CODE_OF_CONDUCT.md`

# Code of Conduct

MacUp should use a standard, recognized open-source code of conduct before public launch.

Recommended: Contributor Covenant, current stable version.

Do not publish this placeholder as the final policy; replace it with the full chosen text and correct project contact details before launch.


---

# SOURCE FILE: `config.example.json`

```json
{
  "schemaVersion": 1,
  "global": {
    "defaultPolicy": "ask",
    "confirmMajorUpdates": true
  },
  "providers": {
    "homebrew": {
      "enabled": true,
      "policy": "ask"
    },
    "npm": {
      "enabled": true,
      "policy": "ask"
    },
    "mise": {
      "enabled": true,
      "policy": "ask"
    },
    "macos": {
      "enabled": true,
      "policy": "ask"
    }
  },
  "items": {
    "npm:@anthropic-ai/claude-code": {
      "policy": "ask"
    },
    "brew:postgresql": {
      "policy": "ignore"
    }
  },
  "schedule": {
    "enabled": false,
    "frequency": "daily",
    "time": "23:00"
  },
  "privacy": {
    "telemetry": false
  }
}
```


---

# SOURCE FILE: `.github/pull_request_template.md`

## What changed

## Why

## Trust/security impact

- [ ] Read-only behavior remains read-only
- [ ] No shell interpolation added
- [ ] Policies are still enforced at execution
- [ ] No secrets added to logs
- [ ] No new privilege behavior
- [ ] N/A explained below

## Tests

## Manual verification


---

# SOURCE FILE: `.github/ISSUE_TEMPLATE/bug.md`

---
name: Bug report
about: Report incorrect or unexpected behavior
---

## MacUp version

## macOS version

## Provider(s)

## What happened

## What you expected

## Safe diagnostics

Please redact usernames, tokens, private paths, project names, or other sensitive information before posting logs.


---

# SOURCE FILE: `.github/ISSUE_TEMPLATE/provider.md`

---
name: Provider request
about: Propose support for another package manager/tool ecosystem
---

## Provider

## Official documentation

## Read-only outdated command/API

## Per-item update capability

## Machine-readable output

## Verification method

## Security/trust considerations
