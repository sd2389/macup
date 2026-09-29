import Foundation

/// "Ask MacUp": a request in plain words, such as "stop updating mysql",
/// turned into one change MacUp can make — or an explanation it can give —
/// that the user then confirms.
///
/// TypeSafe never writes anything and never invents anything. One request
/// asks a fixed set of closed questions at once (docs/cookbooks/function_calling.md):
/// which action out of a short list, which package out of the ones MacUp
/// actually found, which policy, which package manager, and which words of
/// the request are a note. Code reads only the answers the chosen action
/// needs, and trusts the result only as far as the least certain of them.
/// The change it proposes is applied, if at all, by ``PolicyEditor``, after
/// the user has seen exactly what it will write.
public enum AskMacUp {
    /// A sentence, not a document.
    public static let maximumRequestLength = 300
    /// One Choice holds 255 options; one of them is "none of these".
    public static let maximumItemOptions = TypeSafeQuestion.maximumChoiceOptions - 1
    /// Every answer a proposal rests on must be at least this confident, or
    /// MacUp says it is not sure and shows its best guesses instead.
    public static let proposalConfidence = 0.6
    /// `macup ask --yes` applies a change nobody has looked at only when it is
    /// this sure, and only when the change makes MacUp more careful.
    public static let unattendedConfidence = 0.85

    static let noneOfThese = "none_of_these"
}

/// A package MacUp may offer as the one a request is about.
public struct AskItem: Sendable, Hashable, Codable {
    public var id: PackageID
    public var name: String
    public var kind: ItemKind?
    /// The version on offer, when the last check found an update.
    public var offeredVersion: String?

    public init(id: PackageID, name: String, kind: ItemKind? = nil, offeredVersion: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.offeredVersion = offeredVersion
    }

    /// What the option says about the package: its name and what kind of
    /// thing it is, and nothing else from this Mac.
    var optionDescription: String {
        let name = TerminalText.sanitize(name)
        guard let kind else { return name }
        return "\(name), \(kind.askDescription)"
    }
}

extension ItemKind {
    var askDescription: String {
        switch self {
        case .formula: "a Homebrew formula"
        case .cask: "a Homebrew cask"
        case .globalPackage: "a global npm package"
        case .tool: "a tool managed by mise"
        case .systemUpdate: "a macOS update"
        }
    }
}

/// The closed set of things Ask MacUp can do.
public enum AskAction: String, Sendable, Hashable, Codable, CaseIterable {
    case setItemPolicy = "set_item_policy"
    case setProviderPolicy = "set_provider_policy"
    case enableProvider = "enable_provider"
    case disableProvider = "disable_provider"
    case skipVersion = "skip_version"
    case unskipVersion = "unskip_version"
    case addNote = "add_note"
    case explainItem = "explain_item"
    case none

    /// Sent as the option's description, so it says the whole thing.
    var meaning: String {
        switch self {
        case .setItemPolicy:
            "Change how MacUp updates one specific package from now on: update it automatically, ask first, never update it, keep it at its current version, or go back to the default rule."
        case .setProviderPolicy:
            "Change how MacUp updates every package from one package manager at once: Homebrew, npm, mise, or macOS updates."
        case .enableProvider:
            "Start checking a package manager again that MacUp was told to leave alone."
        case .disableProvider:
            "Stop checking one package manager entirely, so none of its packages are shown or updated."
        case .skipVersion:
            "Skip only the version of one package that is on offer now, and offer the next version as usual."
        case .unskipVersion:
            "Stop skipping a version of one package that was skipped before."
        case .addNote:
            "Keep a short note on one package, such as why it is being held back."
        case .explainItem:
            "Explain why MacUp treats one package the way it does, for example why it is held back, ignored, skipped, or waiting for confirmation."
        case .none:
            "Anything else: installing or removing software, a general question, or something unrelated to updating packages."
        }
    }

    var needsItem: Bool {
        [.setItemPolicy, .skipVersion, .unskipVersion, .addNote, .explainItem].contains(self)
    }

    var needsProvider: Bool {
        [.setProviderPolicy, .enableProvider, .disableProvider].contains(self)
    }
}

/// One change to MacUp's configuration, as ``PolicyEditor`` would make it.
public enum AskChange: Sendable, Hashable {
    case setItemPolicy(PackageID, UpdatePolicy)
    case clearItemPolicy(PackageID)
    case setProviderPolicy(ProviderID, UpdatePolicy)
    case setProviderEnabled(ProviderID, Bool)
    case skipVersion(PackageID, String)
    case unskipVersion(PackageID)
    case setNote(PackageID, String)
}

/// A change Ask MacUp proposes, described exactly: what it writes, where,
/// what was there, and the command that makes the same change by hand.
public struct AskProposal: Sendable, Hashable, Identifiable, Encodable {
    public var change: AskChange
    /// The least confident of the answers this rests on.
    public var confidence: Double
    public var title: String
    /// What the change means for the user's updates, in one sentence.
    public var effect: String
    /// Where it lives in the configuration file, such as `items.brew:mysql.policy`.
    public var path: String
    public var currentValue: String
    public var newValue: String
    /// Whether the change lets MacUp do more without asking: an Auto Update
    /// rule, a provider turned back on, a skipped version brought back.
    public var loosens: Bool
    /// The command that makes the same change without Ask MacUp.
    public var command: String

    public var id: String { command }

    /// Whether `macup ask --yes` may apply it without showing it first.
    public var appliesWithoutReview: Bool {
        !loosens && confidence >= AskMacUp.unattendedConfidence
    }

    /// Applies the change through the one editor allowed to make it.
    public func apply(with editor: PolicyEditor) throws -> PolicyChange {
        switch change {
        case .setItemPolicy(let item, let policy): try editor.setPolicy(policy, for: item)
        case .clearItemPolicy(let item): try editor.clearPolicy(for: item)
        case .setProviderPolicy(let provider, let policy): try editor.setPolicy(policy, for: provider)
        case .setProviderEnabled(let provider, let enabled): try editor.setProviderEnabled(enabled, for: provider)
        case .skipVersion(let item, let version): try editor.skipVersion(version, for: item)
        case .unskipVersion(let item): try editor.clearSkippedVersion(for: item)
        case .setNote(let item, let note): try editor.setNote(note, for: item)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case confidence, title, effect, path, currentValue, newValue, loosens, command, change
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(title, forKey: .title)
        try container.encode(effect, forKey: .effect)
        try container.encode(path, forKey: .path)
        try container.encode(currentValue, forKey: .currentValue)
        try container.encode(newValue, forKey: .newValue)
        try container.encode(loosens, forKey: .loosens)
        try container.encode(command, forKey: .command)
        var change = container.nestedContainer(keyedBy: TypeSafeKey.self, forKey: .change)
        switch self.change {
        case .setItemPolicy(let item, let policy):
            try change.encode("setItemPolicy", forKey: TypeSafeKey("kind"))
            try change.encode(item, forKey: TypeSafeKey("item"))
            try change.encode(policy, forKey: TypeSafeKey("policy"))
        case .clearItemPolicy(let item):
            try change.encode("clearItemPolicy", forKey: TypeSafeKey("kind"))
            try change.encode(item, forKey: TypeSafeKey("item"))
        case .setProviderPolicy(let provider, let policy):
            try change.encode("setProviderPolicy", forKey: TypeSafeKey("kind"))
            try change.encode(provider, forKey: TypeSafeKey("provider"))
            try change.encode(policy, forKey: TypeSafeKey("policy"))
        case .setProviderEnabled(let provider, let enabled):
            try change.encode("setProviderEnabled", forKey: TypeSafeKey("kind"))
            try change.encode(provider, forKey: TypeSafeKey("provider"))
            try change.encode(enabled, forKey: TypeSafeKey("enabled"))
        case .skipVersion(let item, let version):
            try change.encode("skipVersion", forKey: TypeSafeKey("kind"))
            try change.encode(item, forKey: TypeSafeKey("item"))
            try change.encode(version, forKey: TypeSafeKey("version"))
        case .unskipVersion(let item):
            try change.encode("unskipVersion", forKey: TypeSafeKey("kind"))
            try change.encode(item, forKey: TypeSafeKey("item"))
        case .setNote(let item, let note):
            try change.encode("setNote", forKey: TypeSafeKey("kind"))
            try change.encode(item, forKey: TypeSafeKey("item"))
            try change.encode(note, forKey: TypeSafeKey("note"))
        }
    }
}

/// What MacUp can say about one item without changing anything.
public struct AskExplanation: Sendable, Hashable, Encodable {
    public var item: PackageID
    /// Display-safe sentences, most important first.
    public var lines: [String]

    public init(item: PackageID, lines: [String]) {
        self.item = item
        self.lines = lines
    }
}

/// What Ask MacUp made of a request.
public struct AskInterpretation: Sendable, Hashable, Encodable {
    public enum Outcome: Sendable, Hashable {
        /// One change, confident enough to put to the user.
        case proposal(AskProposal)
        /// Read-only information about an item.
        case explanation(AskExplanation)
        /// Not confident enough; the best guesses, each a change the user may pick.
        case unsure([AskProposal])
        /// The request is about a package or package manager MacUp could not
        /// match to one it found.
        case noMatch([AskProposal])
        /// Understood, but not something MacUp can do here, and why.
        case notPossible(String)
        /// Not a request for anything Ask MacUp does.
        case notUnderstood
    }

    /// What was sent to TypeSafe, after redaction.
    public var request: String
    /// The versioned model that answered.
    public var model: String
    public var action: AskAction
    /// The least confident of the answers the outcome rests on.
    public var confidence: Double
    public var outcome: Outcome
    /// How many packages were offered, and how many MacUp knew of when it
    /// had to choose the closest ones.
    public var offeredItems: Int
    public var knownItems: Int

    public var proposal: AskProposal? {
        if case .proposal(let proposal) = outcome { return proposal }
        return nil
    }

    public var guesses: [AskProposal] {
        switch outcome {
        case .unsure(let guesses), .noMatch(let guesses): guesses
        default: []
        }
    }

    /// One display-safe sentence about the outcome.
    public var message: String {
        let percent = AskMacUp.percent(confidence)
        switch outcome {
        case .proposal:
            return "MacUp understood this, and TypeSafe is \(percent) sure. Nothing changes until you confirm."
        case .explanation:
            return "Here is what MacUp knows. Nothing was changed."
        case .unsure(let guesses):
            return guesses.isEmpty
                ? "MacUp is not sure what you meant (TypeSafe is \(percent) sure), so it changed nothing."
                : "MacUp is not sure what you meant (TypeSafe is \(percent) sure), so it changed nothing. Its best guesses are below."
        case .noMatch(let guesses):
            return guesses.isEmpty
                ? "MacUp could not match that to a package or package manager it found on this Mac, so it changed nothing."
                : "MacUp could not match that to a package or package manager it found on this Mac, so it changed nothing. The closest are below."
        case .notPossible(let reason):
            return reason
        case .notUnderstood:
            return "MacUp could not turn that into something it can do. It can change how one package or one package manager is updated, turn a package manager on or off, skip a version, keep a note, or explain why a package is held."
        }
    }

    private enum CodingKeys: String, CodingKey {
        case request, model, action, confidence, outcome, proposal, guesses, explanation, message, offeredItems, knownItems
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(request, forKey: .request)
        try container.encode(model, forKey: .model)
        try container.encode(action, forKey: .action)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(message, forKey: .message)
        try container.encode(offeredItems, forKey: .offeredItems)
        try container.encode(knownItems, forKey: .knownItems)
        try container.encode(guesses, forKey: .guesses)
        let name: String
        switch outcome {
        case .proposal(let proposal):
            name = "proposal"
            try container.encode(proposal, forKey: .proposal)
        case .explanation(let explanation):
            name = "explanation"
            try container.encode(explanation, forKey: .explanation)
        case .unsure: name = "unsure"
        case .noMatch: name = "noMatch"
        case .notPossible: name = "notPossible"
        case .notUnderstood: name = "notUnderstood"
        }
        try container.encode(name, forKey: .outcome)
    }
}

/// What Ask MacUp may offer, taken from a check and the configuration.
public struct AskContext: Sendable {
    public var items: [AskItem]
    public var updates: [UpdateCandidate]
    public var configuration: LoadedConfiguration
    /// Used to shorten paths the user typed to `~` before anything is sent.
    public var homeDirectory: String

    public init(items: [AskItem], updates: [UpdateCandidate], configuration: LoadedConfiguration, homeDirectory: String) {
        self.items = items
        self.updates = updates
        self.configuration = configuration
        self.homeDirectory = homeDirectory
    }

    /// Every package the check found — with an update or installed — and
    /// every package the configuration has a rule for, once each.
    public init(report: CheckReport, configuration: LoadedConfiguration, homeDirectory: String) {
        var items: [PackageID: AskItem] = [:]
        for update in report.updates {
            items[update.id] = AskItem(
                id: update.id,
                name: update.displayName,
                kind: update.kind,
                offeredVersion: update.availableVersion.raw
            )
        }
        for provider in report.providers {
            for item in provider.items ?? [] where items[item.id] == nil {
                items[item.id] = AskItem(id: item.id, name: item.displayName, kind: item.kind)
            }
        }
        for key in configuration.configuration.items.keys {
            guard let id = try? PackageID(parsing: key), items[id] == nil else { continue }
            items[id] = AskItem(id: id, name: id.name)
        }
        self.init(
            items: items.values.sorted { $0.id < $1.id },
            updates: report.updates,
            configuration: configuration,
            homeDirectory: homeDirectory
        )
    }
}

extension AIService {
    /// Asks TypeSafe what `text` means and composes the answer in code. One
    /// request; nothing is changed here. Throws ``AIError``.
    public func ask(_ text: String, context: AskContext, environment: [String: String]) async throws -> AskInterpretation {
        let prepared = try AskMacUp.prepare(text, homeDirectory: context.homeDirectory)
        let (client, _) = try client(context.configuration, environment: environment)
        let offered = AskMacUp.offeredItems(context.items, for: prepared)
        let notes = AskMacUp.noteCandidates(in: prepared)
        let response = try await client.ask(
            state: .object(["request": .string(prepared)]),
            questions: AskMacUp.questions(items: offered, notes: notes)
        )
        return AskMacUp.interpret(
            response,
            request: prepared,
            items: offered,
            knownItems: context.items.count,
            notes: notes,
            context: context
        )
    }
}

extension AskMacUp {
    // MARK: Preparing the request

    /// The request as it will be sent: one line, anything secret-shaped
    /// replaced, the home folder shortened to `~`. Throws when there is
    /// nothing to send or too much.
    public static func prepare(_ text: String, homeDirectory: String) throws -> String {
        var line = ""
        for scalar in text.unicodeScalars {
            line.unicodeScalars.append(TerminalText.isUnsafe(scalar) ? " " : scalar)
        }
        let redacted = Redactor(homeDirectory: homeDirectory).redact(line)
        let collapsed = redacted.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else {
            throw AIError(.invalidRequest, "There is nothing to ask. Type what you would like MacUp to do.")
        }
        guard collapsed.count <= maximumRequestLength else {
            throw AIError(
                .requestTooLarge,
                "Keep it to one sentence of at most \(maximumRequestLength) characters. Nothing was sent."
            )
        }
        return collapsed
    }

    /// The packages to offer. With more than one Choice can hold, the ones
    /// whose names are closest to the request, chosen in code; the rest are
    /// never sent.
    static func offeredItems(_ items: [AskItem], for request: String) -> [AskItem] {
        var seen = Set<PackageID>()
        let unique = items.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
        guard unique.count > maximumItemOptions else { return unique }
        let lowered = request.lowercased()
        let requestWords = Set(words(in: lowered))
        let scored: [(item: AskItem, score: Int)] = unique.map { item in
            (item, relevance(of: item, words: requestWords, request: lowered))
        }
        let ranked = scored.sorted { left, right in
            left.score != right.score ? left.score > right.score : left.item.id < right.item.id
        }
        let kept: [AskItem] = ranked.prefix(maximumItemOptions).map(\.item)
        return kept.sorted { $0.id < $1.id }
    }

    static func relevance(of item: AskItem, words: Set<String>, request: String) -> Int {
        let names = [item.id.name.lowercased(), item.name.lowercased()]
        var score = names.contains(where: { $0.count >= 2 && request.contains($0) }) ? 100 : 0
        let itemWords = Set(names.flatMap { Self.words(in: $0) })
        score += 10 * itemWords.intersection(words).count
        score += 3 * itemWords.filter { word in
            words.contains { $0.count >= 3 && word.count >= 3 && (word.hasPrefix($0) || $0.hasPrefix(word)) }
        }.count
        return score
    }

    static func words(in text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Stretches of the request that could be the note it asks for. Jev
    /// picks one; it does not write one (docs/model-jaggedness).
    static func noteCandidates(in request: String) -> [String] {
        var spans: [String] = []
        for (open, close) in [("\"", "\""), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"), ("'", "'")] {
            var rest = Substring(request)
            while let start = rest.range(of: open), let end = rest[start.upperBound...].range(of: close) {
                spans.append(String(rest[start.upperBound..<end.lowerBound]))
                rest = rest[end.upperBound...]
            }
        }
        if let colon = request.firstIndex(of: ":") {
            spans.append(String(request[request.index(after: colon)...]))
        }
        let lowered = request.lowercased()
        for cue in ["because ", "since ", "note that ", "noting that ", "remember that ", "saying ", "that says ", "reason is "] {
            if let range = lowered.range(of: cue) {
                let offset = lowered.distance(from: lowered.startIndex, to: range.upperBound)
                spans.append(String(request.dropFirst(offset)))
            }
        }
        spans.append(request)

        var seen = Set<String>()
        return spans
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!? ")) }
            .filter { !$0.isEmpty && MacUpConfiguration.ItemSettings.problem(withNote: $0) == nil }
            .filter { seen.insert($0).inserted }
            .prefix(8)
            .map { $0 }
    }

    // MARK: The questions

    static let itemPolicies: [(String, UpdatePolicy?, String)] = [
        ("auto", .auto, "Update it automatically, without asking."),
        ("ask", .ask, "Ask before each update of it."),
        ("ignore", .ignore, "Stop updating it and stop showing its updates, whatever version comes out."),
        ("pin", .pin, "Keep it at exactly the version installed now."),
        ("default", nil, "Remove its own rule, so it follows its package manager's rule again."),
    ]

    static let providerPolicies: [(String, UpdatePolicy, String)] = [
        ("auto", .auto, "Update its packages automatically, without asking."),
        ("ask", .ask, "Ask before each update."),
        ("ignore", .ignore, "Leave all of its packages alone."),
        ("default", .inherit, "Go back to MacUp's default rule."),
    ]

    static let providers: [(String, ProviderID?, String)] = [
        ("homebrew", .homebrew, "Homebrew, which installs formulae and casks with brew."),
        ("npm", .npm, "npm, for JavaScript packages installed globally."),
        ("mise", .mise, "mise, which manages language runtimes and tools such as node and python."),
        ("macos", .macos, "macOS software updates from Apple."),
        ("none", nil, "No package manager is named or meant."),
    ]

    /// Every question Ask MacUp might need, asked at once. Code uses only the
    /// ones the chosen action needs; the others cost a few tokens and nothing
    /// else.
    static func questions(items: [AskItem], notes: [String]) -> [String: TypeSafeQuestion] {
        var questions: [String: TypeSafeQuestion] = [
            "action": .choice(
                "What does the user want MacUp to do? MacUp keeps the developer tools on this Mac up to date: it can change how it updates one package or a whole package manager, turn a package manager on or off, skip one version, keep a note on a package, or explain what it does.",
                options: AskAction.allCases.map { .init($0.rawValue, .string($0.meaning)) }
            ),
            "item_policy": .choice(
                "If the user wants to change how MacUp updates one package, what should MacUp do with that package's updates from now on?",
                options: itemPolicies.map { .init($0.0, .string($0.2)) }
            ),
            "provider": .choice(
                "Which package manager, if any, is the request about?",
                options: providers.map { .init($0.0, .string($0.2)) }
            ),
            "provider_policy": .choice(
                "If the user wants to change how MacUp updates a whole package manager, what should MacUp do with its updates from now on?",
                options: providerPolicies.map { .init($0.0, .string($0.2)) }
            ),
        ]
        if !items.isEmpty {
            questions["item"] = .choice(
                "Which one package is the request about? Choose the package the user names or clearly means.",
                options: items.map { .init($0.id.rawValue, .string($0.optionDescription)) }
                    + [.init(noneOfThese, "The request is about none of these packages, about more than one, or about a package manager as a whole.")]
            )
        }
        if !notes.isEmpty {
            questions["note_text"] = .choice(
                "If the user wants MacUp to keep a note on a package, which of these is the note, word for word?",
                options: notes.enumerated().map { .init("note_\($0.offset + 1)", .string($0.element)) }
                    + [.init("none", "The request does not say what the note should be.")]
            )
        }
        return questions
    }

    // MARK: Reading the answers

    /// The answers, composed in code. Pure: no request, no file.
    static func interpret(
        _ response: TypeSafeResponse,
        request: String,
        items: [AskItem],
        knownItems: Int,
        notes: [String],
        context: AskContext
    ) -> AskInterpretation {
        let reader = Reader(response: response, items: items, notes: notes, context: context)
        let (action, outcome, confidence) = reader.outcome()
        return AskInterpretation(
            request: request,
            model: response.model,
            action: action,
            confidence: confidence,
            outcome: outcome,
            offeredItems: items.count,
            knownItems: knownItems
        )
    }

    /// Reads one response. Every question is one this module asked, so a
    /// missing answer is a malformed reply, and a malformed reply was already
    /// refused by ``TypeSafeResponse/decode(_:for:)``.
    private struct Reader {
        let response: TypeSafeResponse
        let items: [AskItem]
        let notes: [String]
        let context: AskContext

        /// One reading: an option for each question the action needs.
        struct Reading: Hashable {
            var action: AskAction
            var item: String?
            var itemPolicy: String?
            var provider: String?
            var providerPolicy: String?
            var note: String?
        }

        func outcome() -> (AskAction, AskInterpretation.Outcome, Double) {
            guard let actionAnswer = response.choice("action"),
                  let action = AskAction(rawValue: actionAnswer.choice)
            else { return (.none, .notUnderstood, 0) }

            let best = Reading(
                action: action,
                item: response.choice("item")?.choice,
                itemPolicy: response.choice("item_policy")?.choice,
                provider: response.choice("provider")?.choice,
                providerPolicy: response.choice("provider_policy")?.choice,
                note: response.choice("note_text")?.choice
            )
            let used = usedQuestions(for: action)
            let confidences = used.compactMap { response.choice($0)?.confidence } + [actionAnswer.confidence]
            let weakest = confidences.min() ?? 0

            if action == .none {
                return (action, .notUnderstood, actionAnswer.confidence)
            }
            // The package or package manager is the one thing the model can
            // only pick, never name. When it picked "none", there is nothing
            // to act on, only the closest candidates to show.
            if action.needsItem, best.item == nil || best.item == AskMacUp.noneOfThese {
                return (action, .noMatch(guesses(varying: "item", from: best)), weakest)
            }
            if action.needsProvider, best.provider == "none" {
                return (action, .noMatch(guesses(varying: "provider", from: best)), weakest)
            }
            guard weakest >= AskMacUp.proposalConfidence else {
                let weakestQuestion = (used + ["action"]).min {
                    (response.choice($0)?.confidence ?? 1) < (response.choice($1)?.confidence ?? 1)
                } ?? "action"
                return (action, .unsure(guesses(varying: weakestQuestion, from: best)), weakest)
            }
            if action == .explainItem, let id = best.item.flatMap({ try? PackageID(parsing: $0) }) {
                return (action, .explanation(AskMacUp.explanation(of: id, context: context)), weakest)
            }
            switch build(best, confidence: weakest) {
            case .success(let proposal):
                return (action, .proposal(proposal), weakest)
            case .failure(let reason):
                return (action, .notPossible(reason.message), weakest)
            }
        }

        func usedQuestions(for action: AskAction) -> [String] {
            switch action {
            case .setItemPolicy: ["item", "item_policy"]
            case .skipVersion, .unskipVersion, .explainItem: ["item"]
            case .addNote: ["item", "note_text"]
            case .setProviderPolicy: ["provider", "provider_policy"]
            case .enableProvider, .disableProvider: ["provider"]
            case .none: []
            }
        }

        /// Up to three proposals, taking the most likely options of one
        /// question and keeping the best answer to every other.
        func guesses(varying question: String, from best: Reading) -> [AskProposal] {
            guard let answer = response.choice(question) else { return [] }
            var proposals: [AskProposal] = []
            for (option, probability) in answer.ranked where probability > 0.02 {
                var reading = best
                switch question {
                case "action": reading.action = AskAction(rawValue: option) ?? .none
                case "item": reading.item = option
                case "item_policy": reading.itemPolicy = option
                case "provider": reading.provider = option
                case "provider_policy": reading.providerPolicy = option
                case "note_text": reading.note = option
                default: break
                }
                if case .success(let proposal) = build(reading, confidence: probability),
                   !proposals.contains(where: { $0.change == proposal.change }) {
                    proposals.append(proposal)
                }
                if proposals.count == 3 { break }
            }
            return proposals
        }

        struct Refusal: Error {
            let message: String
        }

        func build(_ reading: Reading, confidence: Double) -> Result<AskProposal, Refusal> {
            let configuration = context.configuration.configuration
            func item() -> AskItem? {
                guard let key = reading.item, key != AskMacUp.noneOfThese else { return nil }
                return items.first { $0.id.rawValue == key }
            }
            func provider() -> ProviderID? {
                AskMacUp.providers.first { $0.0 == reading.provider }?.1
            }
            switch reading.action {
            case .setItemPolicy:
                guard let item = item(), let policy = AskMacUp.itemPolicies.first(where: { $0.0 == reading.itemPolicy }) else {
                    return .failure(Refusal(message: "MacUp could not tell which package you meant, so it changed nothing."))
                }
                let change: AskChange = policy.1.map { .setItemPolicy(item.id, $0) } ?? .clearItemPolicy(item.id)
                return .success(AskMacUp.describe(change, item: item, confidence: confidence, configuration: configuration))
            case .skipVersion:
                guard let item = item() else { return .failure(Refusal(message: "MacUp could not tell which package you meant, so it changed nothing.")) }
                guard let version = item.offeredVersion else {
                    return .failure(Refusal(message: "MacUp found no update for \(TerminalText.sanitize(item.name)) in the last check, so there is no version to skip."))
                }
                return .success(AskMacUp.describe(.skipVersion(item.id, version), item: item, confidence: confidence, configuration: configuration))
            case .unskipVersion:
                guard let item = item() else { return .failure(Refusal(message: "MacUp could not tell which package you meant, so it changed nothing.")) }
                guard configuration.items[item.id.rawValue]?.skipVersion != nil else {
                    return .failure(Refusal(message: "\(TerminalText.sanitize(item.name)) skips no version, so there is nothing to stop skipping."))
                }
                return .success(AskMacUp.describe(.unskipVersion(item.id), item: item, confidence: confidence, configuration: configuration))
            case .addNote:
                guard let item = item() else { return .failure(Refusal(message: "MacUp could not tell which package you meant, so it changed nothing.")) }
                guard let key = reading.note, key.hasPrefix("note_"), let index = Int(key.dropFirst(5)),
                      notes.indices.contains(index - 1)
                else {
                    return .failure(Refusal(message: "MacUp could not tell which words to keep as the note, so it changed nothing. Add it with `macup policy note \(CommandInvocation.quoted(item.id.rawValue)) \"…\"`."))
                }
                return .success(AskMacUp.describe(.setNote(item.id, notes[index - 1]), item: item, confidence: confidence, configuration: configuration))
            case .setProviderPolicy:
                guard let provider = provider(), let policy = AskMacUp.providerPolicies.first(where: { $0.0 == reading.providerPolicy }) else {
                    return .failure(Refusal(message: "MacUp could not tell which package manager you meant, so it changed nothing."))
                }
                return .success(AskMacUp.describe(.setProviderPolicy(provider, policy.1), item: nil, confidence: confidence, configuration: configuration))
            case .enableProvider, .disableProvider:
                guard let provider = provider() else {
                    return .failure(Refusal(message: "MacUp could not tell which package manager you meant, so it changed nothing."))
                }
                return .success(AskMacUp.describe(
                    .setProviderEnabled(provider, reading.action == .enableProvider),
                    item: nil,
                    confidence: confidence,
                    configuration: configuration
                ))
            case .explainItem, .none:
                return .failure(Refusal(message: "That is not a change."))
            }
        }
    }

    // MARK: Describing a change

    static func describe(_ change: AskChange, item: AskItem?, confidence: Double, configuration: MacUpConfiguration) -> AskProposal {
        let engine = PolicyEngine(configuration: configuration)
        func name(_ id: PackageID) -> String { TerminalText.sanitize(item?.name ?? id.name) }
        func quoted(_ id: PackageID) -> String { CommandInvocation.quoted(id.rawValue) }
        func rule(_ id: PackageID) -> String {
            configuration.items[id.rawValue].flatMap { $0.policy == .inherit ? nil : $0.policy.displayName } ?? "not set"
        }

        switch change {
        case .setItemPolicy(let id, let policy):
            let effect: String = switch policy {
            case .auto: "MacUp may update \(name(id)) without asking. A major, risky, or unknown change still waits for you."
            case .ask: "MacUp will ask before each update of \(name(id))."
            case .ignore: "MacUp will leave \(name(id)) alone, whatever version comes out."
            case .pin: "MacUp will keep \(name(id)) at the version installed now. Its package manager is not told."
            case .inherit: "\(name(id)) will follow the rule for \(id.provider.displayName) again."
            }
            return AskProposal(
                change: change,
                confidence: confidence,
                title: "Set \(id.rawValue) to \(policy.displayName)",
                effect: effect,
                path: "items.\(id.rawValue).policy",
                currentValue: rule(id),
                newValue: policy.displayName,
                loosens: strictness(policy) < strictness(engine.effectivePolicy(for: id).policy),
                command: "macup policy set \(quoted(id)) \(policy.rawValue)"
            )
        case .clearItemPolicy(let id):
            var after = configuration
            after.items[id.rawValue]?.policy = .inherit
            let inherited = PolicyEngine(configuration: after).effectivePolicy(for: id).policy
            return AskProposal(
                change: change,
                confidence: confidence,
                title: "Remove the rule of its own from \(id.rawValue)",
                effect: "\(name(id)) will follow the rule for \(id.provider.displayName) again, which is \(inherited.displayName).",
                path: "items.\(id.rawValue).policy",
                currentValue: rule(id),
                newValue: "not set",
                loosens: strictness(inherited) < strictness(engine.effectivePolicy(for: id).policy),
                command: "macup policy clear \(quoted(id))"
            )
        case .setProviderPolicy(let provider, let policy):
            let settings = configuration.settings(for: provider)
            let global = configuration.global.defaultPolicy
            let before = settings.policy == .inherit ? global : settings.policy
            let after = policy == .inherit ? global : policy
            let effect: String = switch policy {
            case .auto: "MacUp may update \(provider.displayName) packages without asking, unless one has a rule of its own. A major, risky, or unknown change still waits for you."
            case .ask: "MacUp will ask before each \(provider.displayName) update, unless a package has a rule of its own."
            case .ignore: "MacUp will leave every \(provider.displayName) package alone, unless one has a rule of its own."
            case .inherit, .pin: "\(provider.displayName) packages will follow MacUp's default rule, which is \(global.displayName)."
            }
            return AskProposal(
                change: change,
                confidence: confidence,
                title: policy == .inherit
                    ? "Set \(provider.displayName) back to the default"
                    : "Set \(provider.displayName) to \(policy.displayName)",
                effect: effect,
                path: "providers.\(provider.rawValue).policy",
                currentValue: settings.policy.displayName,
                newValue: policy.displayName,
                loosens: strictness(after) < strictness(before),
                command: "macup policy set \(provider.rawValue) \(policy.rawValue)"
            )
        case .setProviderEnabled(let provider, let enabled):
            let current = configuration.settings(for: provider).enabled
            return AskProposal(
                change: change,
                confidence: confidence,
                title: enabled ? "Turn on \(provider.displayName)" : "Turn off \(provider.displayName)",
                effect: enabled
                    ? "MacUp will check \(provider.displayName) again and show its updates."
                    : "MacUp will stop checking \(provider.displayName). Nothing is uninstalled.",
                path: "providers.\(provider.rawValue).enabled",
                currentValue: current ? "on" : "off",
                newValue: enabled ? "on" : "off",
                loosens: enabled && !current,
                command: "macup provider \(enabled ? "enable" : "disable") \(provider.rawValue)"
            )
        case .skipVersion(let id, let version):
            let safe = TerminalText.sanitize(version)
            return AskProposal(
                change: change,
                confidence: confidence,
                title: "Skip \(id.rawValue) \(safe)",
                effect: "MacUp will leave \(safe) alone and offer the next version of \(name(id)) as usual.",
                path: "items.\(id.rawValue).skipVersion",
                currentValue: configuration.items[id.rawValue]?.skipVersion.map(TerminalText.sanitize) ?? "not set",
                newValue: safe,
                loosens: false,
                command: "macup policy skip \(quoted(id)) --version \(CommandInvocation.quoted(version))"
            )
        case .unskipVersion(let id):
            let skipped = configuration.items[id.rawValue]?.skipVersion.map(TerminalText.sanitize) ?? "not set"
            return AskProposal(
                change: change,
                confidence: confidence,
                title: "Stop skipping \(id.rawValue) \(skipped)",
                effect: "\(skipped) will follow the rule for \(name(id)) again.",
                path: "items.\(id.rawValue).skipVersion",
                currentValue: skipped,
                newValue: "not set",
                loosens: true,
                command: "macup policy unskip \(quoted(id))"
            )
        case .setNote(let id, let note):
            let safe = TerminalText.sanitize(note)
            return AskProposal(
                change: change,
                confidence: confidence,
                title: "Keep a note on \(id.rawValue)",
                effect: "“\(safe)” will be shown beside \(name(id)). A note never changes what MacUp does.",
                path: "items.\(id.rawValue).note",
                currentValue: configuration.items[id.rawValue]?.note.map { "“\(TerminalText.sanitize($0))”" } ?? "not set",
                newValue: "“\(safe)”",
                loosens: false,
                command: "macup policy note \(quoted(id)) \(CommandInvocation.quoted(note))"
            )
        }
    }

    /// How much a policy holds MacUp back: never updating is the most, asking
    /// first less, updating without asking the least.
    static func strictness(_ policy: UpdatePolicy) -> Int {
        switch policy {
        case .ignore, .pin: 2
        case .ask, .inherit: 1
        case .auto: 0
        }
    }

    // MARK: Explaining

    /// What MacUp can say about one item from the rules and the last check.
    /// Read-only: the policy decision and its reason, the rule behind it, a
    /// skipped version, the user's note, and the notes the provider gave.
    static func explanation(of item: PackageID, context: AskContext) -> AskExplanation {
        let configuration = context.configuration.configuration
        let engine = PolicyEngine(context.configuration)
        var lines: [String] = []
        if let update = context.updates.first(where: { $0.id == item }) {
            let decision = engine.decide(update, intent: .interactive)
            let versions = "\(TerminalText.sanitize(update.installedVersion?.raw ?? "Unknown")) → \(TerminalText.sanitize(update.availableVersion.raw))"
            lines.append("\(TerminalText.sanitize(update.displayName)) has an update, \(versions) (\(update.versionChange.displayName)).")
            lines.append(TerminalText.sanitize(decision.reason))
            lines += update.notes.map(TerminalText.sanitize)
        } else {
            lines.append("MacUp found no update for \(TerminalText.sanitize(item.name)) in the last check.")
            let (policy, source) = engine.effectivePolicy(for: item)
            let origin: String = switch source {
            case .item: "a rule you set for it (items.\(item.rawValue).policy)"
            case .provider: "the rule for \(item.provider.displayName) (providers.\(item.provider.rawValue).policy)"
            default: "MacUp's default (global.defaultPolicy)"
            }
            lines.append("Its rule is \(policy.displayName), from \(origin).")
            if !configuration.settings(for: item.provider).enabled {
                lines.append("\(item.provider.displayName) is turned off in MacUp, so MacUp does not check it at all.")
            }
        }
        if let skipped = configuration.items[item.rawValue]?.skipVersion {
            lines.append("You skipped version \(TerminalText.sanitize(skipped)).")
        }
        if let note = configuration.items[item.rawValue]?.note {
            lines.append("Your note: “\(TerminalText.sanitize(note))”")
        }
        return AskExplanation(item: item, lines: lines)
    }

    /// A probability as a whole percentage, never 100%: nothing TypeSafe
    /// estimates is certain.
    public static func percent(_ probability: Double) -> String {
        "\(min(99, max(0, Int((probability * 100).rounded(.down)))))%"
    }
}
