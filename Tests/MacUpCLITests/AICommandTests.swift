import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import macup

@Suite("macup ai, macup ask, and macup insight")
struct AICommandTests {
    /// Obviously not a real key; no test has or needs one.
    static let key = "ts_test_not_a_real_key_0123456789"

    private func harness(
        transport: FakeTypeSafeTransport = FakeTypeSafeTransport(),
        store: FakeAPIKeyStore = FakeAPIKeyStore(key: AICommandTests.key),
        secret: String? = nil,
        enabled: Bool = true
    ) throws -> CLIHarness {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.ai = CLIAIServices(
            service: AIService(transport: transport, keyStore: store, sleep: { _ in }),
            readSecret: { _ in secret }
        )
        if enabled { try harness.writeConfig(#"{"schemaVersion": 1, "ai": {"enabled": true}}"#) }
        return harness
    }

    private func aiSection(_ harness: CLIHarness) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: harness.configDirectory.appending("config.json").path) else { return nil }
        return try harness.readConfig()["ai"] as? [String: Any]
    }

    // MARK: status

    @Test("Status says where the key comes from and never prints it")
    func status() async throws {
        let off = try harness(store: FakeAPIKeyStore(), enabled: false)
        let none = try await off.run(["ai"])
        #expect(none.exitCode == nil)
        #expect(none.standardOutput.contains("AI help from TypeSafe · off"))
        #expect(none.standardOutput.contains("Key: none"))

        let keychain = try harness()
        keychain.environment["TYPESAFE_API_KEY"] = "ts_test_environment_key_0123456789"
        let run = try await keychain.run(["ai", "status"])
        #expect(run.standardOutput.contains("AI help from TypeSafe · on"))
        #expect(run.standardOutput.contains("in the Keychain (dev.macup.typesafe); TYPESAFE_API_KEY is also set and is not used"))
        #expect(!run.standardOutput.contains(Self.key))
        #expect(!run.standardOutput.contains("ts_test_environment_key"))

        let json = try await keychain.run(["ai", "status", "--json"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.standardOutput.utf8)) as? [String: Any])
        #expect(object["kind"] as? String == "aiStatus")
        #expect(object["keySource"] as? String == "keychain")
        #expect(object["active"] as? Bool == true)
        #expect(!json.standardOutput.contains(Self.key))
    }

    // MARK: enable / disable

    @Test("Enabling needs a key, and a yes after the disclosure, and a script must say --yes")
    func enable() async throws {
        let noKey = try harness(store: FakeAPIKeyStore(), enabled: false)
        let refused = try await noKey.run(["ai", "enable", "--yes"])
        #expect(refused.exitCode == MacUpExitCode.failure.rawValue)
        #expect(refused.standardError.contains("no TypeSafe API key"))
        #expect(try aiSection(noKey) == nil)

        let script = try harness(enabled: false)
        let noTerminal = try await script.run(["ai", "enable"])
        #expect(noTerminal.exitCode == MacUpExitCode.usage.rawValue)
        #expect(noTerminal.standardOutput.contains("What MacUp sends to TypeSafe"), "the disclosure is shown before anything is asked")
        #expect(try aiSection(script) == nil)

        let terminal = try harness(enabled: false)
        terminal.isTerminal = true
        terminal.answers = ["n"]
        _ = try await terminal.run(["ai", "enable"])
        #expect(try aiSection(terminal) == nil, "anything but yes is a no")
        terminal.answers = ["y"]
        let yes = try await terminal.run(["ai", "enable"])
        #expect(yes.exitCode == nil)
        #expect(yes.standardOutput.contains("Nothing has been sent"))
        #expect(try aiSection(terminal)?["enabled"] as? Bool == true)

        let disabled = try await terminal.run(["ai", "disable"])
        #expect(disabled.exitCode == nil)
        #expect(try aiSection(terminal) == nil, "turning it off leaves the file as it was")
    }

    @Test("Turning AI help on is a change, so it waits for the device owner's approval when that is required")
    func enableNeedsApproval() async throws {
        let harness = try harness(enabled: false)
        try harness.writeConfig(#"{"schemaVersion": 1, "security": {"requireApproval": true}}"#)
        harness.authorizer.set(outcome: .declined("You cancelled, so nothing was changed."))
        let run = try await harness.run(["ai", "enable", "--yes"])
        #expect(run.exitCode == MacUpExitCode.notApproved.rawValue)
        #expect(try aiSection(harness) == nil)
    }

    // MARK: key

    @Test("A key is read without echo, saved in the Keychain, and never printed")
    func keySet() async throws {
        let store = FakeAPIKeyStore()
        let harness = try harness(store: store, secret: "  \(Self.key)\n", enabled: false)
        let run = try await harness.run(["ai", "key", "set"])
        #expect(run.exitCode == nil)
        #expect(store.key == (try TypeSafeAPIKey(validating: Self.key)))
        #expect(run.standardOutput.contains("Saved the key in your login keychain as dev.macup.typesafe"))
        #expect(!(run.standardOutput + run.standardError).contains(Self.key))

        let cleared = try await harness.run(["ai", "key", "clear"])
        #expect(cleared.standardOutput.contains("Removed the TypeSafe key"))
        #expect(store.key == nil)
    }

    @Test("A key given as an argument is refused, and not repeated back")
    func keyAsArgument() async throws {
        let store = FakeAPIKeyStore()
        let harness = try harness(store: store, enabled: false)
        let run = try await harness.run(["ai", "key", "set", Self.key])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(!(run.standardOutput + run.standardError).contains(Self.key))
        #expect(store.key == nil)
    }

    // MARK: test

    @Test("The connection test sends one tiny request when AI help is on, and nothing when it is off")
    func connectionTest() async throws {
        let transport = FakeTypeSafeTransport()
        transport.answerEveryRequest(TypeSafeReply.answering(noul: { _ in 0.98 }))
        let off = try harness(transport: transport, enabled: false)
        let refused = try await off.run(["ai", "test"])
        #expect(refused.exitCode == MacUpExitCode.failure.rawValue)
        #expect(refused.standardError.contains("AI help from TypeSafe is off, so MacUp sent nothing."))
        #expect(transport.requests.isEmpty)

        let on = try harness(transport: transport)
        let run = try await on.run(["ai", "test"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("TypeSafe answered: jev-1.13.0"))
        #expect(transport.requests.count == 1)
    }

    // MARK: ask

    static func mysqlIgnore(_ policy: String = "ignore", confidence: Double = 0.95) -> FakeTypeSafeTransport {
        let transport = FakeTypeSafeTransport()
        transport.answerEveryRequest(TypeSafeReply.answering(choose: { id, _ in
            switch id {
            case "action": ("set_item_policy", confidence)
            case "item": ("brew:mysql", confidence)
            case "item_policy": (policy, confidence)
            default: nil
            }
        }))
        return transport
    }

    private func mysqlPolicy(_ harness: CLIHarness) throws -> String? {
        ((try harness.readConfig()["items"] as? [String: Any])?["brew:mysql"] as? [String: Any])?["policy"] as? String
    }

    @Test("\"stop updating mysql\" shows the exact change, and makes it through PolicyEditor only after a yes")
    func askConfirmed() async throws {
        let transport = Self.mysqlIgnore()
        let harness = try harness(transport: transport)
        harness.isTerminal = true
        harness.answers = ["y"]
        let run = try await harness.run(["ask", "stop updating mysql"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Set brew:mysql to Ignore"))
        #expect(run.standardOutput.contains("items.brew:mysql.policy: not set → Ignore"))
        #expect(run.standardOutput.contains("Same as: macup policy set brew:mysql ignore"))
        #expect(try mysqlPolicy(harness) == "ignore")
        #expect(transport.requests.count == 1)
        #expect(harness.modifyingRequests.isEmpty, "asking changes MacUp's rules, never a package")

        // The packages offered are the ones this Mac has, read-only.
        let items = try #require(((transport.bodies.first?["questions"] as? [String: [String: Any]])?["item"])?["criteria"] as? [String: Any])
        #expect(Set(items.keys).isSuperset(of: ["brew:git", "brew:mysql", "none_of_these"]))
        #expect(items.keys.allSatisfy { $0 == "none_of_these" || $0.hasPrefix("brew:") || $0.hasPrefix("macos:") })
    }

    @Test("Without a terminal, or with --json, nothing is changed and the command to run is printed")
    func askUnconfirmed() async throws {
        let harness = try harness(transport: Self.mysqlIgnore())
        let script = try await harness.run(["ask", "stop updating mysql"])
        #expect(script.exitCode == nil)
        #expect(script.standardOutput.contains("To make this change yourself, run: macup policy set brew:mysql ignore"))
        #expect(try mysqlPolicy(harness) == nil)

        let json = try await harness.run(["ask", "stop updating mysql", "--json"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.standardOutput.utf8)) as? [String: Any])
        #expect(object["kind"] as? String == "ask")
        let interpretation = try #require(object["interpretation"] as? [String: Any])
        #expect(interpretation["outcome"] as? String == "proposal")
        #expect((interpretation["proposal"] as? [String: Any])?["path"] as? String == "items.brew:mysql.policy")
        #expect(object["applied"] == nil)
        #expect(try mysqlPolicy(harness) == nil)
    }

    @Test("--yes applies only a confident change that adds caution; Auto Update always needs a look first")
    func askYes() async throws {
        let careful = try harness(transport: Self.mysqlIgnore(confidence: 0.97))
        let applied = try await careful.run(["ask", "stop updating mysql", "--yes"])
        #expect(applied.exitCode == nil)
        #expect(try mysqlPolicy(careful) == "ignore")

        let loosening = try harness(transport: Self.mysqlIgnore("auto", confidence: 0.99))
        let refused = try await loosening.run(["ask", "auto-update mysql", "--yes"])
        #expect(refused.standardOutput.contains("--yes never makes a change that lets MacUp do more without asking"))
        #expect(try mysqlPolicy(loosening) == nil)
    }

    @Test("With AI help off, ask and insight send nothing and do not even check")
    func offSendsNothing() async throws {
        let transport = Self.mysqlIgnore()
        let harness = try harness(transport: transport, enabled: false)
        let ask = try await harness.run(["ask", "stop updating mysql"])
        #expect(ask.exitCode == MacUpExitCode.failure.rawValue)
        let insight = try await harness.run(["insight", "brew:mysql"])
        #expect(insight.exitCode == MacUpExitCode.failure.rawValue)
        #expect(transport.requests.isEmpty)
        #expect(harness.runner.recordedRequests.isEmpty, "refused before any check ran")
    }

    // MARK: insight

    static func databaseEstimates() -> FakeTypeSafeTransport {
        let transport = FakeTypeSafeTransport()
        transport.answerEveryRequest(TypeSafeReply.answering(
            choose: { id, _ in id == "software_kind" ? ("database", 0.93) : nil },
            noul: { _ in 0.91 }
        ))
        return transport
    }

    @Test("An estimate adds a labelled caution, is asked once, and makes an Auto Update item ask first in plan")
    func insightAndPlan() async throws {
        let transport = Self.databaseEstimates()
        let harness = try harness(transport: transport)
        try harness.writeConfig("""
            {"schemaVersion": 1, "ai": {"enabled": true},
             "global": {"confirmMajorUpdates": false},
             "items": {"brew:mysql": {"policy": "auto"}}}
            """)

        let before = try await harness.run(["plan", "brew:mysql", "--json"])
        let beforePlan = try JSONDecoder.plan.decode(PlanReport.self, from: Data(before.standardOutput.utf8))
        #expect(beforePlan.planned.first?.decision.action == .allow)

        let run = try await harness.run(["insight", "brew:mysql"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Caution: AI estimate from TypeSafe, 91%: mysql looks like a database; a major upgrade may migrate its data on first start — back up first."))
        #expect(run.standardOutput.contains("MacUp will ask before updating it, even though its rule is Auto Update"))
        #expect(transport.requests.count == 1)

        let again = try await harness.run(["insight", "brew:mysql"])
        #expect(again.standardOutput.contains("Saved answer from"))
        #expect(transport.requests.count == 1, "the same version change is not sent twice")

        let after = try await harness.run(["plan", "brew:mysql", "--json"])
        let plan = try JSONDecoder.plan.decode(PlanReport.self, from: Data(after.standardOutput.utf8))
        let decision = try #require(plan.planned.first?.decision)
        #expect(decision.action == .confirm)
        #expect(decision.reason == "An AI estimate from TypeSafe says updating mysql needs extra care, so it asks first.")
        #expect(transport.requests.count == 1, "planning reads the saved estimate and sends nothing")

        // Off means off: the saved caution no longer shapes the plan.
        _ = try await harness.run(["ai", "disable"])
        let off = try await harness.run(["plan", "brew:mysql", "--json"])
        #expect(try JSONDecoder.plan.decode(PlanReport.self, from: Data(off.standardOutput.utf8)).planned.first?.decision.action == .allow)

        let forget = try await harness.run(["ai", "forget"])
        #expect(forget.standardOutput.contains("Deleted 1 AI estimate"))
    }
}
