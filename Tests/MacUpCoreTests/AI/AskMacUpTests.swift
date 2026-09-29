import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Ask MacUp")
struct AskMacUpTests {
    static let key = "ts_test_not_a_real_key_0123456789"
    static let home = "/Users/example"

    static let mysql = try! PackageID(parsing: "brew:mysql")
    static let git = try! PackageID(parsing: "brew:git")
    static let claude = try! PackageID(parsing: "npm:@anthropic-ai/claude-code")

    /// A pretend Mac: mysql and git have updates, claude-code is installed.
    static func context(_ configuration: MacUpConfiguration = .defaults) -> AskContext {
        let updates = [
            UpdateCandidate(id: mysql, kind: .formula, displayName: "mysql", installedVersion: "8.4.3", availableVersion: "9.1.0"),
            UpdateCandidate(id: git, kind: .formula, displayName: "git", installedVersion: "2.43.0", availableVersion: "2.44.0"),
        ]
        return AskContext(
            items: updates.map { AskItem(id: $0.id, name: $0.displayName, kind: $0.kind, offeredVersion: $0.availableVersion.raw) }
                + [AskItem(id: claude, name: "@anthropic-ai/claude-code", kind: .globalPackage)],
            updates: updates,
            configuration: LoadedConfiguration(configuration: configuration, source: .file, path: "/Users/example/.config/macup/config.json"),
            homeDirectory: home
        )
    }

    static func onConfiguration(_ base: MacUpConfiguration = .defaults) -> MacUpConfiguration {
        var configuration = base
        configuration.ai = MacUpConfiguration.AISettings(enabled: true)
        return configuration
    }

    /// Answers as a model would that read the request the given way.
    static func transport(_ answers: [String: (String, Double)]) -> FakeTypeSafeTransport {
        let transport = FakeTypeSafeTransport()
        transport.answerEveryRequest(TypeSafeReply.answering(choose: { id, options in
            guard let (option, probability) = answers[id] else { return nil }
            return options.contains(option) ? (option, probability) : nil
        }))
        return transport
    }

    private func ask(
        _ text: String,
        _ answers: [String: (String, Double)],
        configuration: MacUpConfiguration = onConfiguration()
    ) async throws -> (AskInterpretation, FakeTypeSafeTransport) {
        let transport = Self.transport(answers)
        let service = AIService(transport: transport, keyStore: FakeAPIKeyStore(key: Self.key))
        let result = try await service.ask(text, context: Self.context(configuration), environment: [:])
        return (result, transport)
    }

    // MARK: What is sent

    @Test("One request carries what was typed and the packages MacUp found, and nothing else from this Mac")
    func whatIsSent() async throws {
        let (_, transport) = try await ask(
            "stop updating mysql, it lives in /Users/example/db and the token is ghp_abcdefghijklmnopqrstuvwxyz0123",
            ["action": ("set_item_policy", 0.97), "item": ("brew:mysql", 0.96), "item_policy": ("ignore", 0.93)]
        )
        #expect(transport.requests.count == 1)
        let body = try #require(transport.bodies.first)
        let state = try #require(body["state"] as? [String: String])
        #expect(Array(state.keys) == ["request"])
        let request = try #require(state["request"])
        #expect(request.contains("stop updating mysql"))
        #expect(request.contains("~/db"), "the home folder is shortened before anything is sent")
        #expect(!request.contains("/Users/example"))
        #expect(!request.contains("ghp_"), "anything secret-shaped is removed before anything is sent")

        let questions = try #require(body["questions"] as? [String: [String: Any]])
        #expect(Set(questions.keys) == ["action", "item", "item_policy", "provider", "provider_policy", "note_text"])
        let items = try #require(questions["item"]?["criteria"] as? [String: String])
        #expect(Set(items.keys) == ["brew:mysql", "brew:git", "npm:@anthropic-ai/claude-code", "none_of_these"])
        #expect(items["brew:mysql"] == "mysql, a Homebrew formula")
        let actions = try #require(questions["action"]?["criteria"] as? [String: String])
        #expect(Set(actions.keys) == Set(AskAction.allCases.map(\.rawValue)))

        let text = String(decoding: try #require(transport.requests.first).body, as: UTF8.self)
        for private_ in ["/Users/example", "8.4.3", "config.json", "PATH"] {
            #expect(!text.contains(private_), "\(private_) was sent")
        }
    }

    @Test("With more packages than one Choice holds, the closest to the request are offered, the named one among them")
    func narrowing() {
        var items = (0..<400).map { AskItem(id: try! PackageID(.brew, "tool\($0)"), name: "tool\($0)") }
        items.append(AskItem(id: Self.mysql, name: "mysql"))
        let offered = AskMacUp.offeredItems(items, for: "why is mysql held?")
        #expect(offered.count == AskMacUp.maximumItemOptions)
        #expect(offered.contains { $0.id == Self.mysql })
        #expect(AskMacUp.offeredItems(items, for: "why is mysql held?") == offered, "the same request always offers the same packages")
    }

    @Test("A request that is empty or too long is refused before anything is sent")
    func refusedRequests() throws {
        #expect(throws: AIError.self) { _ = try AskMacUp.prepare("   \n ", homeDirectory: Self.home) }
        #expect(throws: AIError.self) { _ = try AskMacUp.prepare(String(repeating: "a", count: 301), homeDirectory: Self.home) }
        #expect(try AskMacUp.prepare("stop\nupdating\u{1B}[31m mysql", homeDirectory: Self.home) == "stop updating [31m mysql")
    }

    // MARK: Routing

    @Test("\"stop updating mysql\" becomes an exact, confirmable change")
    func itemPolicy() async throws {
        let (result, _) = try await ask(
            "stop updating mysql",
            ["action": ("set_item_policy", 0.97), "item": ("brew:mysql", 0.96), "item_policy": ("ignore", 0.93)]
        )
        let proposal = try #require(result.proposal)
        #expect(proposal.change == .setItemPolicy(Self.mysql, .ignore))
        #expect(proposal.title == "Set brew:mysql to Ignore")
        #expect(proposal.path == "items.brew:mysql.policy")
        #expect(proposal.currentValue == "not set")
        #expect(proposal.newValue == "Ignore")
        #expect(proposal.command == "macup policy set brew:mysql ignore")
        #expect(!proposal.loosens)
        #expect(proposal.confidence == result.confidence)
        #expect(result.model == "jev-1.13.0")
    }

    @Test("Package managers are chosen from the four MacUp knows, and Auto Update is marked as loosening")
    func providers() async throws {
        let (off, _) = try await ask("turn off mise", ["action": ("disable_provider", 0.98), "provider": ("mise", 0.97)])
        #expect(off.proposal?.change == .setProviderEnabled(.mise, false))
        #expect(off.proposal?.command == "macup provider disable mise")
        #expect(off.proposal?.loosens == false)

        let (auto, _) = try await ask(
            "auto-update my npm tools",
            ["action": ("set_provider_policy", 0.95), "provider": ("npm", 0.97), "provider_policy": ("auto", 0.94)]
        )
        let proposal = try #require(auto.proposal)
        #expect(proposal.change == .setProviderPolicy(.npm, .auto))
        #expect(proposal.loosens, "Auto Update lets MacUp do more without asking")
        #expect(!proposal.appliesWithoutReview)
    }

    @Test("\"skip this mysql version\" skips exactly the version on offer; a package with none cannot be skipped")
    func skipVersion() async throws {
        let (skip, _) = try await ask("skip this mysql version", ["action": ("skip_version", 0.95), "item": ("brew:mysql", 0.96)])
        #expect(skip.proposal?.change == .skipVersion(Self.mysql, "9.1.0"))
        #expect(skip.proposal?.command == "macup policy skip brew:mysql --version 9.1.0")

        let (nothing, _) = try await ask(
            "skip the claude code update",
            ["action": ("skip_version", 0.95), "item": ("npm:@anthropic-ai/claude-code", 0.95)]
        )
        guard case .notPossible(let reason) = nothing.outcome else {
            Issue.record("expected notPossible, got \(nothing.outcome)")
            return
        }
        #expect(reason.contains("no version to skip"))
    }

    @Test("A note is picked from the words of the request, never written by the model")
    func note() async throws {
        let (result, transport) = try await ask(
            "note on mysql: waiting for the schema migration",
            ["action": ("add_note", 0.95), "item": ("brew:mysql", 0.96), "note_text": ("note_1", 0.9)]
        )
        let body = try #require(transport.bodies.first)
        let notes = try #require((body["questions"] as? [String: [String: Any]])?["note_text"]?["criteria"] as? [String: String])
        #expect(notes["note_1"] == "waiting for the schema migration")
        #expect(result.proposal?.change == .setNote(Self.mysql, "waiting for the schema migration"))
    }

    @Test("\"why is mysql held?\" explains, from the rules and the last check, and changes nothing")
    func explain() async throws {
        var configuration = Self.onConfiguration()
        configuration.items[Self.mysql.rawValue] = MacUpConfiguration.ItemSettings(policy: .ignore, note: "waiting for the migration")
        let (result, _) = try await ask(
            "why is mysql held?",
            ["action": ("explain_item", 0.96), "item": ("brew:mysql", 0.97)],
            configuration: configuration
        )
        guard case .explanation(let explanation) = result.outcome else {
            Issue.record("expected an explanation, got \(result.outcome)")
            return
        }
        #expect(explanation.item == Self.mysql)
        #expect(explanation.lines.contains { $0.contains("is ignored (a rule you set for this item)") })
        #expect(explanation.lines.contains("Your note: “waiting for the migration”"))
        #expect(result.proposal == nil)
    }

    // MARK: Confidence

    @Test("When the least certain answer is below the bar, MacUp says it is not sure and shows its best guesses")
    func unsure() async throws {
        // item_policy split between ignore and pin, as "stop updating" might be.
        let context = Self.context(Self.onConfiguration())
        let prepared = try AskMacUp.prepare("stop updating mysql", homeDirectory: Self.home)
        let offered = AskMacUp.offeredItems(context.items, for: prepared)
        let response = TypeSafeResponse(
            model: "jev-1.13.0",
            answers: [
                "action": .choice(TypeSafeChoiceAnswer(choice: "set_item_policy", probabilities: ["set_item_policy": 0.97, "none": 0.03], confidence: 0.96)),
                "item": .choice(TypeSafeChoiceAnswer(choice: "brew:mysql", probabilities: ["brew:mysql": 0.98, "brew:git": 0.02], confidence: 0.97)),
                "item_policy": .choice(TypeSafeChoiceAnswer(choice: "ignore", probabilities: ["ignore": 0.52, "pin": 0.46, "ask": 0.02], confidence: 0.4)),
                "provider": .choice(TypeSafeChoiceAnswer(choice: "none", probabilities: ["none": 1], confidence: 1)),
                "provider_policy": .choice(TypeSafeChoiceAnswer(choice: "ask", probabilities: ["ask": 1], confidence: 1)),
            ]
        )
        let result = AskMacUp.interpret(response, request: prepared, items: offered, knownItems: offered.count, notes: [], context: context)
        guard case .unsure(let guesses) = result.outcome else {
            Issue.record("expected unsure, got \(result.outcome)")
            return
        }
        #expect(result.confidence == 0.4)
        // The 2% option is too unlikely to be worth offering.
        #expect(guesses.map(\.change) == [.setItemPolicy(Self.mysql, .ignore), .setItemPolicy(Self.mysql, .pin)])
        #expect(result.proposal == nil, "nothing is proposed as the answer when MacUp is not sure")
        #expect(result.message.contains("not sure"))
    }

    @Test("A request about no package MacUp found proposes nothing, and anything else is not understood")
    func noMatchAndNone() async throws {
        let (noMatch, _) = try await ask(
            "stop updating postgres",
            ["action": ("set_item_policy", 0.95), "item": ("none_of_these", 0.9), "item_policy": ("ignore", 0.9)]
        )
        guard case .noMatch = noMatch.outcome else {
            Issue.record("expected noMatch, got \(noMatch.outcome)")
            return
        }
        #expect(noMatch.proposal == nil)

        let (none, _) = try await ask("install postgres", ["action": ("none", 0.95)])
        #expect(none.outcome == .notUnderstood)
    }

    // MARK: Applying

    @Test("A confirmed proposal is applied by PolicyEditor, and only there")
    func applyThroughPolicyEditor() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-ask")
        let file = directory.appending("config.json")
        try #"{"schemaVersion": 1, "ai": {"enabled": true}}"#.write(to: file, atomically: true, encoding: .utf8)
        let store = ConfigurationStore(fileURL: file)
        let loaded = store.load()
        #expect(!loaded.hasErrors)

        let transport = Self.transport(["action": ("set_item_policy", 0.97), "item": ("brew:mysql", 0.96), "item_policy": ("ignore", 0.93)])
        let service = AIService(transport: transport, keyStore: FakeAPIKeyStore(key: Self.key))
        var context = Self.context()
        context.configuration = loaded
        let result = try await service.ask("stop updating mysql", context: context, environment: [:])

        // Interpreting wrote nothing.
        #expect(store.load().configuration.items.isEmpty)

        let change = try #require(result.proposal).apply(with: PolicyEditor(store: store))
        #expect(change.changed)
        #expect(change.path == "items.brew:mysql.policy")
        #expect(store.load().configuration.items["brew:mysql"]?.policy == .ignore)
        #expect(store.load().configuration.aiSettings.enabled, "the rest of the file is kept")
    }

    @Test("With AI help off, asking sends nothing")
    func offSendsNothing() async throws {
        let transport = Self.transport(["action": ("none", 0.9)])
        let service = AIService(transport: transport, keyStore: FakeAPIKeyStore(key: Self.key))
        let error = await #expect(throws: AIError.self) {
            _ = try await service.ask("stop updating mysql", context: Self.context(.defaults), environment: [:])
        }
        #expect(error?.kind == .disabled)
        #expect(transport.requests.isEmpty)
    }
}
