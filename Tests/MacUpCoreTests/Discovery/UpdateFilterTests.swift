import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Filtering and sorting the update list")
struct UpdateFilterTests {
    private static func update(
        _ id: String,
        _ installed: String? = "1.0.0",
        _ available: String = "1.0.1",
        name: String? = nil,
        signals: Set<RiskSignal> = []
    ) -> UpdateCandidate {
        PlannedUpdateFactory.candidate(id, installed: installed, available: available, signals: signals, displayName: name)
    }

    private static func ids(_ updates: [UpdateCandidate]) -> [String] { updates.map(\.id.rawValue) }

    private static func checkReport(_ updates: [UpdateCandidate]) -> CheckReport {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        return CheckReport(
            mode: .readOnly,
            startedAt: date,
            finishedAt: date,
            cancelled: false,
            configuration: ConfigurationSummary(LoadedConfiguration(
                configuration: .defaults,
                source: .defaults,
                path: "/Users/example/.config/macup/config.json"
            )),
            providers: [],
            updates: updates,
            commands: []
        )
    }

    @Test("Needs attention is the small, explicit set MacUpCore defines")
    func attentionSet() {
        #expect(RiskSignal.needingAttention == [.buildsFromSource, .installationIncomplete])
        #expect(Self.update("brew:a", signals: [.installationIncomplete]).needsAttention)
        #expect(Self.update("brew:b", signals: [.buildsFromSource]).needsAttention)
        #expect(!Self.update("brew:c", signals: [.mayAffectDependents, .restartRequired]).needsAttention)
    }

    @Test("By provider: MacUp's provider order, then package ID, which is the order a check reports")
    func providerOrder() {
        let updates = ["macos:Safari-1", "npm:b", "mise:node", "brew:zsh", "npm:a", "brew-cask:firefox"].map { Self.update($0) }
        let listing = UpdateFilter().apply(to: updates, sortedBy: .provider, effectivePolicies: [:])
        #expect(Self.ids(listing.shown) == ["brew-cask:firefox", "brew:zsh", "npm:a", "npm:b", "mise:node", "macos:Safari-1"])
        #expect(listing.groups.map(\.provider) == [.homebrew, .npm, .mise, .macos])
        #expect(listing.groups.map(\.updates.count) == [2, 2, 1, 1])
        #expect(listing.hiddenCount == 0)
    }

    @Test("By risk: high, then unknown, then moderate, then low; ties keep the provider order")
    func riskOrder() {
        let updates = [
            Self.update("npm:low", "1.0.0", "1.0.1"),
            Self.update("brew:moderate", "1.0.0", "1.1.0"),
            Self.update("npm:high", "1.0.0", "2.0.0"),
            Self.update("brew:unknown", "abc", "def"),
            Self.update("brew:high", "1.0.0", "2.0.0"),
        ]
        #expect(updates.map(\.risk.level) == [.low, .moderate, .high, .unknown, .high])
        let listing = UpdateFilter().apply(to: updates, sortedBy: .risk, effectivePolicies: [:])
        #expect(Self.ids(listing.shown) == ["brew:high", "npm:high", "brew:unknown", "brew:moderate", "npm:low"])
        #expect(listing.groups.count == 1, "one list, not one per provider")
        #expect(listing.groups.first?.provider == nil)
    }

    @Test("By name: ignoring case, numbers in numeric order, ties by provider")
    func nameOrder() {
        let updates = [
            Self.update("npm:node10", name: "node10"),
            Self.update("brew:zeta", name: "Zeta"),
            Self.update("npm:node2", name: "Node2"),
            Self.update("npm:alpha", name: "alpha"),
            Self.update("brew:alpha", name: "alpha"),
        ]
        let listing = UpdateFilter().apply(to: updates, sortedBy: .name, effectivePolicies: [:])
        #expect(Self.ids(listing.shown) == ["brew:alpha", "npm:alpha", "npm:node2", "npm:node10", "brew:zeta"])
    }

    @Test("By size of change: major, minor, patch, build, revision, pre-release, downgrade, none, unknown")
    func changeOrder() {
        let updates = [
            Self.update("brew:unknown", "abc", "def"),
            Self.update("brew:none", "1.0.0", "1.0.0"),
            Self.update("brew:downgrade", "2.0.0", "1.0.0"),
            Self.update("brew:prerelease", "1.0.0", "1.1.0-rc.1"),
            Self.update("brew:revision", "1.2.3", "1.2.3_1"),
            Self.update("brew:build", "1.0.0.1", "1.0.0.2"),
            Self.update("brew:patch", "1.0.0", "1.0.1"),
            Self.update("brew:minor", "1.0.0", "1.1.0"),
            Self.update("brew:major", "1.0.0", "2.0.0"),
        ]
        #expect(updates.map(\.versionChange) == [.unknown, .none, .downgrade, .prerelease, .revision, .build, .patch, .minor, .major])
        let listing = UpdateFilter().apply(to: updates, sortedBy: .change, effectivePolicies: [:])
        #expect(listing.shown.map(\.versionChange)
            == [.major, .minor, .patch, .build, .revision, .prerelease, .downgrade, .none, .unknown])
        #expect(Set(listing.shown.map(\.versionChange)) == Set(VersionChange.allCases), "every kind of change has a place")
    }

    @Test("Search looks at the name, the package ID, and the provider, ignoring case and accents")
    func search() {
        let updates = [
            Self.update("brew:git", name: "git"),
            Self.update("npm:@anthropic-ai/claude-code", name: "Claude Code"),
            Self.update("brew:brulee", name: "Crème Brûlée"),
        ]
        func shown(_ text: String) -> [String] {
            Self.ids(UpdateFilter(searchText: text).apply(to: updates, sortedBy: .provider, effectivePolicies: [:]).shown)
        }
        #expect(shown("GIT") == ["brew:git"])
        #expect(shown("anthropic") == ["npm:@anthropic-ai/claude-code"], "the package ID")
        #expect(shown("npm:@anth") == ["npm:@anthropic-ai/claude-code"])
        #expect(shown("homebrew") == ["brew:brulee", "brew:git"], "the provider")
        #expect(shown("creme") == ["brew:brulee"], "accents are ignored")
        #expect(shown("claude npm") == ["npm:@anthropic-ai/claude-code"], "every word has to match somewhere")
        #expect(shown("claude homebrew").isEmpty)
        #expect(shown("   ").count == 3, "a blank search hides nothing")
        #expect(!UpdateFilter(searchText: " \n ").isActive)
    }

    @Test("Criteria combine; the choices within one criterion are alternatives")
    func combinedCriteria() {
        let mysql = Self.update("brew:mysql", "9.7.1", "26.7.0_2", signals: [.installationIncomplete])
        let weird = Self.update("npm:weird", "abc", "def")
        let typescript = Self.update("npm:typescript", "5.8.0", "5.9.0")
        let node = Self.update("mise:node", "24.19.0", "24.19.1", signals: [.buildsFromSource])
        let updates = [mysql, weird, typescript, node]
        #expect(updates.map(\.risk.level) == [.high, .unknown, .moderate, .moderate])
        let policies: [PackageID: UpdatePolicy] = [mysql.id: .ask, weird.id: .auto, typescript.id: .ask, node.id: .ignore]
        func shown(_ filter: UpdateFilter) -> [String] {
            Self.ids(filter.apply(to: updates, sortedBy: .provider, effectivePolicies: policies).shown)
        }
        #expect(shown(UpdateFilter(riskLevels: [.high, .unknown])) == ["brew:mysql", "npm:weird"])
        #expect(shown(UpdateFilter(riskLevels: [.high, .unknown], policies: [.ask])) == ["brew:mysql"])
        #expect(shown(UpdateFilter(policies: [.ask, .ignore])) == ["brew:mysql", "npm:typescript", "mise:node"])
        #expect(shown(UpdateFilter(needsAttentionOnly: true)) == ["brew:mysql", "mise:node"])
        #expect(shown(UpdateFilter(providers: [.npm], riskLevels: [.moderate])) == ["npm:typescript"])
        #expect(shown(UpdateFilter(searchText: "type", needsAttentionOnly: true)).isEmpty)
        #expect(shown(UpdateFilter(policies: [.inherit])).isEmpty, "no policy in effect is inherit")

        let unknownPolicies = UpdateFilter(policies: [.ask]).apply(to: updates, sortedBy: .provider, effectivePolicies: [:])
        #expect(unknownPolicies.shown.isEmpty, "an update whose policy is not known is not claimed to be Ask First")
        #expect(unknownPolicies.hiddenCount == 4)
    }

    @Test("What a filter hides is kept and counted, overall and per provider")
    func hiddenCounts() {
        let updates = [Self.update("brew:a", "1.0.0", "2.0.0"), Self.update("brew:b"), Self.update("npm:c"), Self.update("macos:d")]
        let listing = UpdateFilter(riskLevels: [.high]).apply(to: updates, sortedBy: .name, effectivePolicies: [:])
        #expect(Self.ids(listing.shown) == ["brew:a"])
        #expect(Self.ids(listing.hidden) == ["brew:b", "npm:c", "macos:d"], "in the order given")
        #expect(listing.hiddenCount == 3)
        #expect(listing.totalCount == 4)
        #expect(listing.hiddenCount(for: .homebrew) == 1)
        #expect(listing.hiddenCount(for: .npm) == 1)
        #expect(listing.hiddenCount(for: .mise) == 0)
        #expect(UpdateFilter(riskLevels: [.unknown]).apply(to: updates, sortedBy: .provider, effectivePolicies: [:]).groups.isEmpty)
        #expect(!UpdateFilter().isActive)
    }

    @Test("A filter describes itself in words, in a stable order")
    func summaryWords() {
        let filter = UpdateFilter(
            searchText: "  git ",
            providers: [.npm, .homebrew],
            riskLevels: [.low, .high, .unknown],
            policies: [.ignore, .auto],
            needsAttentionOnly: true
        )
        #expect(filter.summary == "matching “git”, Homebrew or npm, high or unknown or low risk, Auto Update or Ignore, needs attention")
        #expect(UpdateFilter().summary.isEmpty)
    }

    @Test("A filtered check lists what matches and still counts everything it found")
    func filteredCheckReport() throws {
        let report = Self.checkReport([
            Self.update("brew:git", "2.43.0", "2.44.0"),
            Self.update("brew:mysql", "9.7.1", "26.7.0_2"),
            Self.update("npm:npm", "11.17.0", "12.1.0"),
        ])
        let filtered = report.filtered(UpdateFilter(riskLevels: [.high]), sortedBy: .name, effectivePolicies: [:])
        #expect(Self.ids(filtered.updates) == ["brew:mysql", "npm:npm"])
        #expect(filtered.summary == report.summary)
        #expect(filtered.summary.updatesAvailable == 3)
        let recorded = try #require(filtered.filter)
        #expect(recorded.riskLevels == [.high])
        #expect(recorded.sort == .name)
        #expect(recorded.shown == 2)
        #expect(recorded.hidden == 1)
        #expect(report.filter == nil)
    }

    @Test("Only a filtered report carries a filter, with just the fields it used")
    func filterEncoding() throws {
        let git = Self.update("brew:git")
        let report = Self.checkReport([git])
        let encoder = JSONEncoder()
        let plain = try #require(try JSONSerialization.jsonObject(with: encoder.encode(report)) as? [String: Any])
        #expect(plain["filter"] == nil, "an unfiltered report encodes as it always has")

        let filtered = report.filtered(
            UpdateFilter(policies: [.ask], needsAttentionOnly: true),
            sortedBy: .risk,
            effectivePolicies: [git.id: .ask]
        )
        let object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(filtered)) as? [String: Any])
        let filter = try #require(object["filter"] as? [String: Any])
        #expect(Set(filter.keys) == ["riskLevels", "policies", "needsAttentionOnly", "sort", "shown", "hidden"])
        #expect(filter["policies"] as? [String] == ["ask"])
        #expect(filter["sort"] as? String == "risk")
        #expect(filter["shown"] as? Int == 0)
        #expect(filter["hidden"] as? Int == 1)
        #expect(try JSONDecoder().decode(CheckReport.self, from: encoder.encode(filtered)).filter == filtered.filter)

        let everything = UpdateFilter(searchText: "git", providers: [.npm], riskLevels: [.low], policies: [.pin], needsAttentionOnly: true)
        #expect(ReportFilter(everything, sort: .change, shown: 1, hidden: 2).criteria == everything)
    }

    @Test("A filtered plan judges a skipped item by the update behind it, and keeps what it cannot judge")
    func filteredPlan() throws {
        let git = Self.update("brew:git", "2.43.0", "2.44.0")
        let wget = Self.update("brew:wget", "1.0.0", "1.0.1")
        let mysql = Self.update("brew:mysql", "9.7.1", "26.7.0_2")
        let node = Self.update("mise:node", "22.0.0", "24.0.0")
        let step = PlannedUpdateFactory.step("/stub/bin/brew", ["example", "git"])
        let plan = PlannedUpdateFactory.report(
            [
                PlannedUpdateFactory.planned(git, steps: [step], action: .allow, policy: .auto),
                PlannedUpdateFactory.planned(wget, steps: [step], action: .confirm, policy: .ask),
            ],
            skipped: [
                SkippedUpdate(
                    mysql,
                    decision: PolicyDecision(item: mysql.id, action: .deny, policy: .ignore, source: .item, reason: "mysql is ignored."),
                    reason: "mysql is ignored."
                ),
                SkippedUpdate(
                    node,
                    decision: PolicyDecision(item: node.id, action: .confirm, policy: .ask, source: .global, reason: "Ask first."),
                    reason: "MacUp cannot plan node."
                ),
                SkippedUpdate(item: try PackageID(parsing: "npm:ghost"), displayName: "ghost", reason: "Nothing behind it."),
            ]
        )
        let candidates = [git, wget, mysql, node]

        let high = plan.filtered(UpdateFilter(riskLevels: [.high]), sortedBy: .name, candidates: candidates)
        #expect(high.planned.isEmpty)
        #expect(high.skipped.map(\.item.rawValue) == ["brew:mysql", "mise:node", "npm:ghost"], "sorted, the unjudged one last")
        #expect(high.summary == plan.summary, "the counts are the whole plan's")
        #expect(high.filter?.shown == 3)
        #expect(high.filter?.hidden == 2)

        let ask = plan.filtered(UpdateFilter(policies: [.ask]), sortedBy: .provider, candidates: candidates)
        #expect(ask.planned.map(\.item.rawValue) == ["brew:wget"], "the policy is the one the plan's decision names")
        #expect(ask.skipped.map(\.item.rawValue) == ["mise:node", "npm:ghost"])
    }
}
