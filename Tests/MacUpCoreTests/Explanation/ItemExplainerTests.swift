import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// `macup explain` and the app's Copy Details, from the engine's side: every
/// kind of item MacUp can be asked about, on a pretend Mac whose providers are
/// the real ones reading fixture output.
@Suite("Item explainer", .timeLimit(.minutes(1)))
struct ItemExplainerTests {
    let explainer = ItemExplainer.standard()
    let defaults = LoadedConfiguration(
        configuration: .defaults,
        source: .defaults,
        path: "/Users/example/.config/macup/config.json"
    )

    private func configuration(_ mutate: (inout MacUpConfiguration) -> Void) -> LoadedConfiguration {
        var configuration = MacUpConfiguration.defaults
        mutate(&configuration)
        return LoadedConfiguration(configuration: configuration, source: .file, path: "/Users/example/.config/macup/config.json")
    }

    private func explain(
        _ id: String,
        configuration: LoadedConfiguration? = nil,
        mac: FakeMac? = nil,
        history: HistoryStore? = nil
    ) async throws -> (explanation: ItemExplanation, mac: FakeMac) {
        let mac = try mac ?? FakeMac()
        let explanation = await explainer.explain(
            try PackageID(parsing: id),
            configuration: configuration ?? defaults,
            environment: mac.checkEnvironment,
            history: history
        )
        return (explanation, mac)
    }

    @Test("An update MacUp can plan carries the exact command, the decision, and the rule behind it")
    func plannableUpdate() async throws {
        let (explanation, mac) = try await explain("brew:git")

        #expect(explanation.schemaVersion == 1)
        #expect(explanation.kind == "explain")
        #expect(explanation.status == .updateAvailable)
        #expect(explanation.update?.installedVersion == "2.43.0")
        #expect(explanation.update?.availableVersion == "2.44.0")
        #expect(explanation.versionDifference?.summary == "Minor 43 → 44.")
        #expect(explanation.installed?.id.rawValue == "brew:git", "the check kept the installed items")

        let step = try #require(explanation.plan?.steps.first)
        #expect(step.invocation.executable == "/opt/homebrew/bin/brew")
        #expect(step.invocation.arguments == ["upgrade", "--formula", "--yes", "git"])
        #expect(explanation.skipped == nil)
        #expect(explanation.commandText == "/opt/homebrew/bin/brew upgrade --formula --yes git")

        #expect(explanation.policy.policy == .ask)
        #expect(explanation.policy.source == .global)
        #expect(explanation.policy.rule == "global.defaultPolicy")
        #expect(explanation.policy.decision?.action == .confirm)
        #expect(explanation.summary == "An update is available: 2.43.0 → 2.44.0. MacUp would apply it once you confirm.")

        // Explaining is a check and a description: every command it ran was
        // on the read-only allowlist, and nothing that changes the Mac ran.
        #expect(!mac.runner.recordedRequests.isEmpty)
        #expect(mac.runner.recordedRequests.allSatisfy { $0.effect == .readOnly })
        for request in mac.runner.recordedRequests {
            #expect(CommandAllowlist.readOnlyCheck.contains { $0.matches(request) })
        }
        // Only the item's own provider is asked.
        #expect(mac.runner.recordedRequests.allSatisfy { $0.executable.lastPathComponent == "brew" })
    }

    @Test("An item set to update without asking says so, and names its own rule")
    func automaticUpdate() async throws {
        let (explanation, _) = try await explain(
            "brew:git",
            configuration: configuration { $0.items["brew:git"] = .init(policy: .auto) }
        )
        #expect(explanation.policy.decision?.action == .allow)
        #expect(explanation.policy.source == .item)
        #expect(explanation.policy.rule == "items.brew:git.policy")
        #expect(explanation.summary.hasSuffix("MacUp would apply it without asking."))
    }

    @Test("An item a rule leaves alone gets the decision and the rule, and no command")
    func ruleLeavesItAlone() async throws {
        let (explanation, _) = try await explain(
            "brew:git",
            configuration: configuration { $0.items["brew:git"] = .init(policy: .ignore) }
        )
        #expect(explanation.status == .updateAvailable)
        #expect(explanation.plan == nil)
        #expect(explanation.commandText == nil)
        #expect(explanation.policy.decision?.action == .deny)
        #expect(explanation.policy.policy == .ignore)
        #expect(explanation.policy.rule == "items.brew:git.policy")
        #expect(explanation.skipped?.decision?.action == .deny)
        #expect(explanation.skipped?.reason.contains("is ignored") == true)
        #expect(explanation.summary.hasSuffix("MacUp leaves it alone."))
    }

    @Test("A turned-off provider decides nothing, even for an item with its own rule")
    func providerRulesOverride() async throws {
        let (explanation, mac) = try await explain(
            "brew:git",
            configuration: configuration {
                $0.providers["homebrew"] = .init(enabled: false)
                $0.items["brew:git"] = .init(policy: .auto)
            }
        )
        #expect(explanation.status == .providerDisabled)
        #expect(explanation.status.isUnknownItem)
        #expect(explanation.summary.contains("turned off"))
        #expect(explanation.suggestion == "`macup provider enable homebrew` turns Homebrew back on.")
        #expect(explanation.policy.source == .item, "the item's own rule is still reported")
        #expect(mac.runner.recordedRequests.isEmpty, "a provider that is off is not run at all")
    }

    @Test("An update MacUp cannot plan says exactly why, with the provider's own words")
    func unplannableUpdate() async throws {
        let (explanation, _) = try await explain("macos:macOS 27.2 Beta-26B5091g")
        #expect(explanation.status == .updateAvailable)
        #expect(explanation.plan == nil)
        #expect(explanation.commandText == nil)
        #expect(explanation.policy.decision?.action == .confirm, "policy would allow it; MacUp cannot do it")
        let skipped = try #require(explanation.skipped)
        #expect(skipped.reason.contains("does not apply them"))
        #expect(skipped.error?.kind == .unsupported)
        #expect(explanation.summary.hasSuffix("MacUp cannot plan it."))
    }

    @Test("A formula Homebrew itself pins is left alone, and the pin is what decided it")
    func providerPin() async throws {
        let mac = try FakeMac()
        mac.runner.register("brew", ["outdated", "--json=v2"], .success(try Fixture.text("homebrew/outdated-pinned.json")))
        let check = await CheckEngine.standard().run(configuration: defaults, environment: mac.checkEnvironment)
        let pinned = try #require(check.updates.first { $0.signals.contains(.pinnedByProvider) })

        let (explanation, _) = try await explain(pinned.id.rawValue, mac: mac)
        #expect(explanation.policy.decision?.source == .providerPin)
        #expect(explanation.policy.decision?.action == .deny)
        #expect(explanation.plan == nil)
    }

    @Test("An installed item with no update is explained as up to date, with nothing to decide")
    func installedWithoutUpdate() async throws {
        let (explanation, _) = try await explain("brew:abseil")
        #expect(explanation.status == .upToDate)
        #expect(explanation.update == nil)
        #expect(explanation.installed?.installedVersions == ["20260817.0"])
        #expect(explanation.plan == nil)
        #expect(explanation.skipped == nil)
        #expect(explanation.policy.decision == nil)
        #expect(explanation.policy.policy == .ask)
        #expect(explanation.summary == "Installed: 20260817.0. Homebrew offers no update for it.")
        #expect(explanation.suggestion == nil)
    }

    @Test("A pinned item with no update says it is pinned")
    func pinnedWithoutUpdate() async throws {
        let (explanation, _) = try await explain("brew:postgresql@16")
        #expect(explanation.status == .upToDate)
        #expect(explanation.installed?.pinnedByProvider == true)
    }

    @Test("An item no provider reports is unknown, and MacUp says where to look instead")
    func unknownItem() async throws {
        let (explanation, _) = try await explain("brew:ripgrep")
        #expect(explanation.status == .notFound)
        #expect(explanation.status.isUnknownItem)
        #expect(explanation.update == nil && explanation.installed == nil)
        #expect(explanation.summary == "Homebrew does not list brew:ripgrep as installed, and offers no update for it.")
        #expect(explanation.suggestion == "`macup check --inventory` lists every item MacUp can see.")
    }

    @Test("A macOS label MacUp was not offered is unknown, without claiming what macOS has installed")
    func unknownMacOSUpdate() async throws {
        let (explanation, _) = try await explain("macos:macOS 99")
        #expect(explanation.status == .notFound)
        #expect(explanation.summary.contains("does not list what macOS has installed"))
        #expect(explanation.suggestion == "`macup check` lists the updates MacUp found.")
    }

    @Test("A provider that is not installed is reported as such, not as an empty result")
    func providerMissing() async throws {
        let (explanation, _) = try await explain("npm:prettier", mac: try FakeMac(installed: false))
        #expect(explanation.status == .providerNotFound)
        #expect(explanation.status.isUnknownItem)
        #expect(explanation.summary.contains("did not find npm"))
    }

    @Test("A failed update check never reads as up to date, and an item it hides is not called unknown")
    func failedCheck() async throws {
        let mac = try FakeMac()
        mac.runner.register("brew", ["outdated", "--json=v2"], .exit(1, standardError: "Error: something broke\n"))

        let (installed, _) = try await explain("brew:abseil", mac: mac)
        #expect(installed.status == .updateUnknown)
        #expect(!installed.status.isUnknownItem)
        #expect(installed.providerReport?.errors.contains { $0.operation == .outdated } == true)

        let (missing, _) = try await explain("brew:ripgrep", mac: mac)
        #expect(missing.status == .checkFailed)
        #expect(!missing.status.isUnknownItem, "MacUp cannot rule it out, so it does not say it knows nothing")
    }

    @Test("A configuration MacUp cannot read decides against every change, and says so")
    func unreadableConfiguration() async throws {
        let broken = LoadedConfiguration(
            configuration: .defaults,
            source: .file,
            path: "/Users/example/.config/macup/config.json",
            issues: [ConfigurationIssue(.error, "global.defaultPolicy", "Not a policy.")]
        )
        let (explanation, _) = try await explain("brew:git", configuration: broken)
        #expect(explanation.configuration.valid == false)
        #expect(explanation.policy.decision?.source == .configuration)
        #expect(explanation.policy.decision?.action == .deny)
        #expect(explanation.plan == nil)
    }

    @Test("History is the item's own entries, newest first, and says when there are more")
    func history() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-explain-history")
        let store = HistoryStore(fileURL: directory.appending("state/macup/history.jsonl"))
        let git = try PackageID(parsing: "brew:git")
        let wget = try PackageID(parsing: "brew:wget")
        for index in 0..<7 {
            try store.append(entry(git, at: Double(index) * 60, before: "2.\(index).0"))
            try store.append(entry(wget, at: Double(index) * 60 + 1, before: "1.\(index).0"))
        }

        let (explanation, _) = try await explain("brew:git", history: store)
        let history = explanation.history
        #expect(history.entries.count == ItemExplainer.historyLimit)
        #expect(history.entries.allSatisfy { $0.item == git })
        #expect(history.entries.map(\.versionBefore) == ["2.6.0", "2.5.0", "2.4.0", "2.3.0", "2.2.0"])
        #expect(history.moreAvailable)
        #expect(history.problem == nil)
    }

    @Test("An item with no history, or no history file at all, says so rather than failing")
    func noHistory() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-explain-history")
        let store = HistoryStore(fileURL: directory.appending("state/macup/history.jsonl"))
        let (explanation, _) = try await explain("brew:git", history: store)
        #expect(explanation.history.entries.isEmpty)
        #expect(!explanation.history.moreAvailable)
        #expect(explanation.history.problem == nil)
        #expect(!FileManager.default.fileExists(atPath: store.path), "reading history never creates it")
    }

    @Test("Explaining from a check that already ran plans without running a single command")
    func fromAnExistingCheck() async throws {
        let mac = try FakeMac()
        let check = await CheckEngine.standard().run(configuration: defaults, environment: mac.checkEnvironment)
        let before = mac.runner.recordedRequests.count

        let explanation = await explainer.explain(
            try PackageID(parsing: "npm:corepack"),
            from: check,
            configuration: defaults,
            environment: mac.checkEnvironment,
            history: nil
        )
        #expect(mac.runner.recordedRequests.count == before)
        #expect(explanation.status == .updateAvailable)
        #expect(explanation.plan?.steps.first?.invocation.arguments.contains("corepack@0.36.0") == true)
        // A check without installed items still knows the update; the
        // inventory entry is simply absent.
        #expect(explanation.installed == nil)
        #expect(explanation.history.problem != nil, "with no store, the explanation says it could not look")
    }

    @Test("The provider's report travels with the explanation, without its installed items")
    func providerReportWithoutItems() async throws {
        let (explanation, _) = try await explain("brew:git")
        let report = try #require(explanation.providerReport)
        #expect(report.executable?.path == "/opt/homebrew/bin/brew")
        #expect(report.items == nil)
    }

    private func entry(_ item: PackageID, at seconds: TimeInterval, before: String) -> HistoryEntry {
        HistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_790_000_000 + seconds),
            origin: .cli,
            item: item,
            versionBefore: before,
            versionTarget: "9.9.9",
            versionAfter: "9.9.9",
            command: "/opt/homebrew/bin/brew upgrade --formula --yes \(item.name)",
            outcome: .succeeded,
            verification: .verified,
            durationSeconds: 2
        )
    }
}
