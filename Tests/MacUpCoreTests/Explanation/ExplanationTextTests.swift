import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// The words `macup explain` prints and the app's Copy Details copies, for
/// each kind of item, from explanations built by hand so a change of wording
/// elsewhere cannot move these.
@Suite("Explanation text")
struct ExplanationTextTests {
    static let home = "/Users/example"
    static let moment = Date(timeIntervalSince1970: 1_790_000_000)
    static let git = try! PackageID(parsing: "brew:git")
    static let brew = ResolvedExecutable(
        path: "/Users/example/.homebrew/bin/brew",
        canonicalPath: "/Users/example/.homebrew/bin/brew",
        source: .searchPath
    )

    let text = ExplanationText(homeDirectory: ExplanationTextTests.home, timeZone: TimeZone(identifier: "UTC")!)

    // MARK: Fixtures

    static func candidate(signals: Set<RiskSignal> = [], notes: [String] = ["A note from the provider."]) -> UpdateCandidate {
        UpdateCandidate(
            id: git,
            kind: .formula,
            displayName: "git",
            installedVersion: "2.43.0",
            availableVersion: "2.44.0",
            signals: signals,
            ownership: OwnershipChain([OwnershipLink(label: "Homebrew", path: "/Users/example/.homebrew")]),
            notes: notes,
            details: ["homepage": "https://git-scm.com"]
        )
    }

    static func decision(
        _ action: PolicyDecision.Action,
        _ policy: UpdatePolicy = .ask,
        source: PolicyDecision.Source = .global,
        reason: String = "git needs your confirmation first (MacUp's default)."
    ) -> PolicyDecision {
        PolicyDecision(item: git, action: action, policy: policy, source: source, reason: reason)
    }

    static func plan(for candidate: UpdateCandidate) -> ExecutionPlan {
        ExecutionPlan(
            createdAt: moment,
            item: git,
            currentVersion: candidate.installedVersion,
            proposedVersion: candidate.availableVersion,
            risk: candidate.risk,
            rationale: "Homebrew upgrades the formula git from 2.43.0 to 2.44.0.",
            steps: [ExecutionStep(
                summary: "Upgrade the formula git",
                invocation: CommandInvocation(executable: brew.path, arguments: ["upgrade", "--formula", "--yes", "git"]),
                effect: .modifying,
                expectsNetwork: true,
                mayRequirePrivilege: false,
                timeoutSeconds: 3600
            )],
            expectsNetwork: true,
            mayRequirePrivilege: false,
            mayRequireRestart: false,
            mayChangeUserConfiguration: false,
            verification: [VerificationStep(
                summary: "Read Homebrew's installed versions back and look for 2.44.0.",
                invocation: CommandInvocation(executable: brew.path, arguments: ["info", "--json=v2", "--installed"]),
                expectedVersion: "2.44.0"
            )],
            rollback: .notImplemented
        )
    }

    static let homebrew = ProviderReport(
        provider: .homebrew,
        displayName: "Homebrew",
        availability: .available,
        capabilities: [.detect, .inventory, .outdated, .planUpdates],
        executable: brew,
        version: "7.0.6"
    )

    static let configuration = ConfigurationSummary(LoadedConfiguration(
        configuration: .defaults,
        source: .defaults,
        path: "/Users/example/.config/macup/config.json"
    ))

    static let succeeded = HistoryEntry(
        timestamp: Date(timeIntervalSince1970: 1_790_000_000),
        origin: .cli,
        item: git,
        versionBefore: "2.42.0",
        versionTarget: "2.43.0",
        versionAfter: "2.43.0",
        command: "/Users/example/.homebrew/bin/brew upgrade --formula --yes git",
        outcome: .succeeded,
        verification: .verified,
        durationSeconds: 12.5
    )

    static func explanation(
        status: ItemExplanation.Status = .updateAvailable,
        summary: String = "An update is available: 2.43.0 → 2.44.0. MacUp would apply it once you confirm.",
        update: UpdateCandidate? = candidate(),
        installed: ManagedItem? = nil,
        policy: ItemExplanation.Policy = .init(policy: .ask, source: .global, rule: "global.defaultPolicy", decision: decision(.confirm)),
        plan: ExecutionPlan? = plan(for: candidate()),
        skipped: SkippedUpdate? = nil,
        history: ItemExplanation.History = .init(entries: [succeeded], limit: 5),
        providerReport: ProviderReport? = homebrew,
        configuration: ConfigurationSummary = configuration
    ) -> ItemExplanation {
        ItemExplanation(
            createdAt: moment,
            item: update?.id ?? installed?.id ?? git,
            status: status,
            summary: summary,
            update: update,
            installed: installed,
            policy: policy,
            plan: plan,
            skipped: skipped,
            history: history,
            providerReport: providerReport,
            configuration: configuration
        )
    }

    // MARK: Each kind of item

    @Test("An update MacUp would run: every section, the exact command, and the history")
    func plannedUpdate() {
        #expect(text.render(Self.explanation()) == """
            MacUp explain · read-only · nothing was changed

            brew:git · Homebrew formula
            An update is available: 2.43.0 → 2.44.0. MacUp would apply it once you confirm.

            Versions
              Installed: 2.43.0
              Available: 2.44.0, a minor change
              What changes: Minor 43 → 44.
              Project home page: https://git-scm.com

            Risk: moderate
              Minor version change

            Notes
              A note from the provider.

            Managed by
              Homebrew · ~/.homebrew
              Checked with ~/.homebrew/bin/brew (Homebrew 7.0.6).

            Policy: Ask First · needs your confirmation
              Set by: the default policy (global.defaultPolicy)
              Why: git needs your confirmation first (MacUp's default).

            What MacUp would run · once you confirm
              Upgrade the formula git
                Runs: ~/.homebrew/bin/brew upgrade --formula --yes git
                Time limit: 1 hour
              Homebrew upgrades the formula git from 2.43.0 to 2.44.0.
              No administrator password · no restart · leaves your configuration alone · uses the network
              Confirms afterwards: Read Homebrew's installed versions back and look for 2.44.0.
                Reads: ~/.homebrew/bin/brew info --json=v2 --installed
              Undo: MacUp has no tested rollback strategy for this action.
              `macup update brew:git` shows this plan, asks you, and then runs it.

            History · 1 entry
              2026-09-21 14:13  Updated and confirmed
                  2.42.0 → 2.43.0 · now 2.43.0
                  via Homebrew · started from the command line · ran for 13 seconds
                  Ran: ~/.homebrew/bin/brew upgrade --formula --yes git
            """)
    }

    @Test("An update that runs without asking says so, and how to run it")
    func automaticUpdate() {
        let rendered = text.render(Self.explanation(policy: .init(
            policy: .auto,
            source: .item,
            rule: "items.brew:git.policy",
            decision: Self.decision(.allow, .auto, source: .item, reason: "git is set to update automatically (a rule you set for this item).")
        )))
        #expect(rendered.contains("Policy: Auto Update · runs without asking"))
        #expect(rendered.contains("  Set by: a rule you set for this item (items.brew:git.policy)"))
        #expect(rendered.contains("What MacUp would run · without asking"))
        #expect(rendered.contains("  `macup update brew:git` runs it."))
        #expect(!rendered.contains("Decided by"), "nothing overrode the rule")
    }

    @Test("An item a rule leaves alone: the rule, no command, and how to remove the rule")
    func leftAloneByRule() {
        let denial = Self.decision(.deny, .ignore, source: .item, reason: "git is ignored (a rule you set for this item).")
        let rendered = text.render(Self.explanation(
            summary: "An update is available: 2.43.0 → 2.44.0. MacUp leaves it alone.",
            policy: .init(policy: .ignore, source: .item, rule: "items.brew:git.policy", decision: denial),
            plan: nil,
            skipped: SkippedUpdate(item: Self.git, displayName: "git", currentVersion: "2.43.0", proposedVersion: "2.44.0", decision: denial, reason: denial.reason)
        ))
        #expect(rendered.contains("""
            Policy: Ignore · will not run
              Set by: a rule you set for this item (items.brew:git.policy)
              Why: git is ignored (a rule you set for this item).

            What MacUp would run: nothing
              The policy above leaves it alone.
              `macup policy clear brew:git` removes the rule for this item.
            """))
        #expect(!rendered.contains("Runs:"))
    }

    @Test("An update MacUp cannot plan gives the provider's reason, detail, and next step")
    func cannotPlan() {
        let rendered = text.render(Self.explanation(
            summary: "An update is available: 2.43.0 → 2.44.0. MacUp cannot plan it.",
            plan: nil,
            skipped: SkippedUpdate(
                item: Self.git,
                displayName: "git",
                decision: Self.decision(.confirm),
                reason: "An earlier install of git did not finish, so MacUp will not start another upgrade on top of it.",
                error: MacUpError(
                    .unsupported,
                    "An earlier install of git did not finish, so MacUp will not start another upgrade on top of it.",
                    detail: "Unfinished: git 2.44.0",
                    recoverySuggestion: "Check `brew info git` and repair or remove the unfinished version yourself."
                )
            )
        ))
        #expect(rendered.contains("""
            What MacUp would run: nothing
              An earlier install of git did not finish, so MacUp will not start another upgrade on top of it.
              Unfinished: git 2.44.0
              Check `brew info git` and repair or remove the unfinished version yourself.
            """))
        #expect(!rendered.contains("Runs:"))
    }

    @Test("What overrode the rule is named: the provider's own pin, risk, a provider turned off")
    func overrides() {
        func rendered(_ source: PolicyDecision.Source, _ action: PolicyDecision.Action = .deny) -> String {
            text.render(Self.explanation(
                policy: .init(policy: .auto, source: .item, rule: "items.brew:git.policy",
                              decision: Self.decision(action, .auto, source: source, reason: "Because.")),
                plan: nil
            ))
        }
        #expect(rendered(.providerPin).contains("  Decided by: Homebrew's own pin, which MacUp never overrides"))
        #expect(rendered(.risk, .confirm).contains("  Decided by: the risk of this change"))
        #expect(rendered(.providerDisabled).contains("  Decided by: Homebrew is turned off in MacUp's configuration (providers.homebrew.enabled)"))
        #expect(rendered(.configuration).contains("  Decided by: MacUp's configuration, which it could not read"))
    }

    @Test("An installed item with no update: its versions, its rule, and that there is nothing to run")
    func upToDate() {
        let node = try! PackageID(parsing: "mise:node")
        let item = ManagedItem(
            id: node,
            kind: .tool,
            displayName: "node",
            installedVersions: ["24.18.0", "24.19.0"],
            activeVersion: "24.19.0",
            ownership: OwnershipChain([OwnershipLink(label: "mise 2026.7.3", path: "/Users/example/.local/bin/mise")])
        )
        let mise = ProviderReport(
            provider: .mise,
            displayName: "mise",
            availability: .available,
            capabilities: [.detect, .inventory, .outdated],
            executable: ResolvedExecutable(path: "/Users/example/.local/bin/mise", canonicalPath: "/Users/example/.local/bin/mise", source: .searchPath),
            version: "2026.7.3"
        )
        let rendered = text.render(Self.explanation(
            status: .upToDate,
            summary: "Installed: 24.19.0 (in use), 24.18.0. mise offers no update for it.",
            update: nil,
            installed: item,
            policy: .init(policy: .ask, source: .global, rule: "global.defaultPolicy"),
            plan: nil,
            history: .init(limit: 5),
            providerReport: mise
        ))
        #expect(rendered == """
            MacUp explain · read-only · nothing was changed

            mise:node · mise tool
            Installed: 24.19.0 (in use), 24.18.0. mise offers no update for it.

            Versions
              Installed: 24.19.0 (in use), 24.18.0
              No update is available.

            Managed by
              mise 2026.7.3 · ~/.local/bin/mise

            Policy: Ask First
              Set by: the default policy (global.defaultPolicy)
              No update is available, so there is nothing to decide yet.

            What MacUp would run: nothing
              There is no update to apply.

            History: nothing recorded for this item.
            """)
    }

    @Test("An item MacUp knows nothing about: why, what it still holds, and where to look")
    func unknownItem() {
        let postgres = try! PackageID(parsing: "brew:postgresql")
        var explanation = Self.explanation(
            status: .notFound,
            summary: "Homebrew does not list brew:postgresql as installed, and offers no update for it.",
            update: nil,
            policy: .init(policy: .ignore, source: .item, rule: "items.brew:postgresql.policy"),
            plan: nil,
            history: .init(entries: [Self.succeeded, Self.succeeded], limit: 5)
        )
        explanation.item = postgres
        #expect(text.unknownItemMessage(explanation) == [
            "Homebrew does not list brew:postgresql as installed, and offers no update for it.",
            "MacUp still has a rule for it: Ignore (items.brew:postgresql.policy).",
            "MacUp's history has 2 entries for it; `macup history` shows them.",
            "`macup check --inventory` lists every item MacUp can see.",
        ])

        // Rendered in full, it keeps to what MacUp knows: no versions, no
        // plan, only the rule that will apply and the history it holds.
        let rendered = text.render(explanation)
        #expect(rendered.contains("brew:postgresql · Homebrew\n"))
        #expect(!rendered.contains("Versions"))
        #expect(!rendered.contains("What MacUp would run"))
        #expect(rendered.contains("Policy: Ignore\n  Set by: a rule you set for this item (items.brew:postgresql.policy)\n  The rule applies to its next update."))
    }

    @Test("A failed check shows what failed before anything else")
    func problems() {
        var report = Self.homebrew
        report.errors = [ProviderOperationError(
            operation: .outdated,
            error: MacUpError(.commandFailed, "`brew outdated` failed.", recoverySuggestion: "Run `brew doctor`.")
        )]
        let rendered = text.render(Self.explanation(
            status: .checkFailed,
            summary: "MacUp could not finish checking Homebrew, so it cannot say whether brew:git is installed or has an update.",
            update: nil,
            plan: nil,
            history: .init(limit: 5),
            providerReport: report
        ))
        #expect(rendered.contains("""
            Problems
              error (update check): `brew outdated` failed.
                Run `brew doctor`.
            """))
        #expect(rendered.hasSuffix("`macup check --verbose` shows what went wrong."))
    }

    @Test("History says when there is more, what could not be read, and when it could not be read at all")
    func historyEdges() {
        let more = text.render(Self.explanation(history: .init(
            entries: [Self.succeeded], limit: 1, moreAvailable: true, unreadableLines: 2
        )))
        #expect(more.contains("History · the most recent entry\n"))
        #expect(more.contains("  `macup history` shows the older ones."))
        #expect(more.contains("  note: 2 lines of MacUp's history could not be read, and they may have been about this item."))

        let unreadable = text.render(Self.explanation(history: .init(limit: 5, problem: "MacUp could not read its history file.")))
        #expect(unreadable.hasSuffix("History: MacUp could not read it.\n  MacUp could not read its history file."))
    }

    // MARK: Safety of the text

    @Test("Provider text cannot act on a terminal, and nothing secret-shaped is copied")
    func untrustedTextIsSafe() {
        let hostile = UpdateCandidate(
            id: Self.git,
            kind: .formula,
            displayName: "git\u{1B}[31m\u{202E}",
            installedVersion: "2.43.0\u{7}",
            availableVersion: "2.44.0",
            ownership: OwnershipChain([OwnershipLink(label: "Home\u{1B}]0;x\u{7}brew", path: "/Users/example/.homebrew")]),
            notes: ["token=ghp_abcdefghijklmnopqrstuvwxyz0123456789", "line one\nline\u{1B}[2J two"]
        )
        let rendered = text.render(Self.explanation(update: hostile, plan: nil))
        #expect(rendered.unicodeScalars.allSatisfy { $0 == "\n" || !TerminalText.isUnsafe($0) })
        #expect(!rendered.contains("\u{1B}"))
        #expect(!rendered.contains("\u{202E}"))
        #expect(!rendered.contains("\u{7}"))
        #expect(rendered.contains(#"git\u{1B}[31m\u{202E}"#))
        #expect(!rendered.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(rendered.contains(Redactor.placeholder))
        #expect(rendered.contains("  line one\n  line\\u{1B}[2J two"), "a note of several lines stays indented")
    }

    @Test("Paths under the home directory are written with ~, and a different home is left alone")
    func homeDirectoryIsAbbreviated() {
        let rendered = text.render(Self.explanation())
        #expect(!rendered.contains("/Users/example"))
        let elsewhere = ExplanationText(homeDirectory: "/Users/someone-else", timeZone: TimeZone(identifier: "UTC")!)
        #expect(elsewhere.render(Self.explanation()).contains("Runs: /Users/example/.homebrew/bin/brew upgrade"))
    }

    @Test("Plain unless the caller styles it, and styling never changes the words")
    func styling() {
        let plain = text.render(Self.explanation())
        #expect(!plain.contains("\u{1B}["))

        let styled = ExplanationText(
            homeDirectory: Self.home,
            timeZone: TimeZone(identifier: "UTC")!,
            bold: { "<b>\($0)</b>" },
            dim: { "<d>\($0)</d>" }
        ).render(Self.explanation())
        #expect(styled.hasPrefix("<b>MacUp explain</b><d> · read-only · nothing was changed</d>"))
        #expect(styled.contains("<b>Policy</b>: Ask First · needs your confirmation"))
        let stripped = styled
            .replacingOccurrences(of: "<b>", with: "").replacingOccurrences(of: "</b>", with: "")
            .replacingOccurrences(of: "<d>", with: "").replacingOccurrences(of: "</d>", with: "")
        #expect(stripped == plain)
    }

    @Test("Copy Command is the plan's exact command line, one per step, redacted")
    func commandText() {
        #expect(Self.explanation().commandText == "/Users/example/.homebrew/bin/brew upgrade --formula --yes git")
        #expect(Self.explanation(plan: nil).commandText == nil)

        var twoSteps = Self.plan(for: Self.candidate())
        twoSteps.steps.append(ExecutionStep(
            summary: "Something with a secret",
            invocation: CommandInvocation(executable: "/usr/bin/true", arguments: ["a b", "--token=ghp_abcdefghijklmnopqrstuvwxyz0123456789"]),
            effect: .modifying,
            expectsNetwork: false,
            mayRequirePrivilege: false,
            timeoutSeconds: 60
        ))
        let lines = Self.explanation(plan: twoSteps).commandText?.split(separator: "\n")
        #expect(lines?.count == 2)
        #expect(lines?.last?.contains("ghp_") == false)
        #expect(lines?.last?.contains(" 'a b' ") == true, "shell-quoted, so it reads as the argument it is")
    }
}
