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
