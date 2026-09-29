import Foundation

// The request and response shapes of TypeSafe's System One endpoint
// (https://docs.typesafe.ai/api.md), and nothing more. Building a request
// validates it against the documented limits before anything is sent, and
// reading a response checks every value MacUp relies on against the question
// that produced it. An answer that does not fit its question is not used at
// all: MacUp fails closed rather than acting on half of a reply.

/// Where MacUp's AI requests go. One host, fixed here; nothing in the
/// configuration or the environment can change it.
public enum TypeSafeEndpoint {
    public static let host = "api.typesafe.ai"
    // A constant that parses; failing would be a programming error.
    // swiftlint:disable:next force_unwrapping
    public static let systemOne = URL(string: "https://api.typesafe.ai/v1/systemone")!
    /// TypeSafe's Data Processing Agreement, which says how it handles and
    /// keeps what it receives. MacUp links it rather than paraphrasing it.
    // swiftlint:disable:next force_unwrapping
    public static let dataProcessingAgreement = URL(string: "https://typesafe.ai/legal/data-processing")!
    public static let requestTimeoutSeconds: Double = 20
    /// Far below the model's documented 64k-token limit. MacUp's requests are
    /// a few kilobytes; anything larger is a mistake worth refusing.
    public static let maximumRequestBytes = 128 * 1024
    public static let maximumResponseBytes = 1 << 20
}

/// A JSON value MacUp builds: a state, an instruction, a description.
public indirect enum TypeSafeValue: Sendable, Hashable, Encodable, ExpressibleByStringLiteral {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([TypeSafeValue])
    case object([String: TypeSafeValue])

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        case .object(let members):
            var container = encoder.container(keyedBy: TypeSafeKey.self)
            for (key, value) in members { try container.encode(value, forKey: TypeSafeKey(key)) }
        }
    }

    /// Whether this is a string with nothing in it, which no question may be.
    var isBlank: Bool {
        if case .string(let text) = self { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return false
    }
}

struct TypeSafeKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) {
        stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

/// One typed question. The id it is asked under is not sent to the model, so
/// the instructions carry the whole question (docs/primitives.md).
public struct TypeSafeQuestion: Sendable, Hashable, Encodable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case choice
        case noul
        case score
    }

    /// One option of a Choice. A `nil` description is sent as JSON null,
    /// which TypeSafe accepts for an option whose name says enough.
    public struct Option: Sendable, Hashable {
        public var key: String
        public var description: TypeSafeValue?

        public init(_ key: String, _ description: TypeSafeValue?) {
            self.key = key
            self.description = description
        }
    }

    public static let maximumChoiceOptions = 255
    public static let scoreLevels = 2...10
    static let maximumOptionKeyLength = 300

    public let kind: Kind
    public let instructions: TypeSafeValue
    /// Choice only, in the order MacUp offers them.
    public let options: [Option]
    /// Score only, lowest first.
    public let levels: [TypeSafeValue]
    /// Noul only: what a yes and a no mean.
    public let yes: TypeSafeValue?
    public let no: TypeSafeValue?

    private init(
        kind: Kind,
        instructions: TypeSafeValue,
        options: [Option] = [],
        levels: [TypeSafeValue] = [],
        yes: TypeSafeValue? = nil,
        no: TypeSafeValue? = nil
    ) {
        self.kind = kind
        self.instructions = instructions
        self.options = options
        self.levels = levels
        self.yes = yes
        self.no = no
    }

    public static func choice(_ instructions: TypeSafeValue, options: [Option]) -> TypeSafeQuestion {
        TypeSafeQuestion(kind: .choice, instructions: instructions, options: options)
    }

    public static func noul(_ instructions: TypeSafeValue, yes: TypeSafeValue? = nil, no: TypeSafeValue? = nil) -> TypeSafeQuestion {
        TypeSafeQuestion(kind: .noul, instructions: instructions, yes: yes, no: no)
    }

    public static func score(_ instructions: TypeSafeValue, levels: [TypeSafeValue]) -> TypeSafeQuestion {
        TypeSafeQuestion(kind: .score, instructions: instructions, levels: levels)
    }

    public var optionKeys: [String] { options.map(\.key) }

    /// Whether this question is one TypeSafe documents as valid. A question
    /// MacUp built wrongly is never sent.
    var isValid: Bool {
        guard !instructions.isBlank else { return false }
        switch kind {
        case .choice:
            let keys = optionKeys
            return (2...Self.maximumChoiceOptions).contains(keys.count)
                && Set(keys).count == keys.count
                && keys.allSatisfy { !$0.isEmpty && $0.count <= Self.maximumOptionKeyLength }
        case .score:
            return Self.scoreLevels.contains(levels.count)
        case .noul:
            return (yes == nil) == (no == nil)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, instructions, criteria
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .type)
        try container.encode(instructions, forKey: .instructions)
        switch kind {
        case .choice:
            var criteria = container.nestedContainer(keyedBy: TypeSafeKey.self, forKey: .criteria)
            for option in options {
                if let description = option.description {
                    try criteria.encode(description, forKey: TypeSafeKey(option.key))
                } else {
                    try criteria.encodeNil(forKey: TypeSafeKey(option.key))
                }
            }
        case .score:
            try container.encode(levels, forKey: .criteria)
        case .noul:
            if let yes, let no {
                var criteria = container.nestedContainer(keyedBy: TypeSafeKey.self, forKey: .criteria)
                try criteria.encode(yes, forKey: TypeSafeKey("true"))
                try criteria.encode(no, forKey: TypeSafeKey("false"))
            }
        }
    }
}

/// The body of `POST /v1/systemone`.
public struct TypeSafeRequest: Sendable, Hashable, Encodable {
    public var model: String
    public var state: TypeSafeValue
    public var questions: [String: TypeSafeQuestion]

    public init(model: String, state: TypeSafeValue, questions: [String: TypeSafeQuestion]) {
        self.model = model
        self.state = state
        self.questions = questions
    }

    /// Question ids are MacUp's own, so they are held to a plain shape.
    static func isValidQuestionID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "_.:-".unicodeScalars.contains(scalar))
        }
    }

    var isValid: Bool {
        !questions.isEmpty
            && MacUpConfiguration.AISettings.isValidModelName(model)
            && questions.allSatisfy { Self.isValidQuestionID($0.key) && $0.value.isValid }
    }

    /// The exact bytes MacUp sends: sorted keys, so the same request is always
    /// the same body.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

// MARK: - Answers

/// A Choice answer: the option chosen, a probability for each option, and how
/// peaked that distribution is.
public struct TypeSafeChoiceAnswer: Sendable, Hashable, Codable {
    public var choice: String
    public var probabilities: [String: Double]
    public var confidence: Double

    public init(choice: String, probabilities: [String: Double], confidence: Double) {
        self.choice = choice
        self.probabilities = probabilities
        self.confidence = confidence
    }

    public func probability(of option: String) -> Double {
        probabilities[option] ?? 0
    }

    /// Options from most to least likely; equal ones in name order, so two
    /// readings of one answer always agree.
    public var ranked: [(option: String, probability: Double)] {
        probabilities
            .map { (option: $0.key, probability: $0.value) }
            .sorted { $0.probability != $1.probability ? $0.probability > $1.probability : $0.option < $1.option }
    }
}

/// A Score answer: a position along the levels, a probability for each level,
/// and how peaked that distribution is.
public struct TypeSafeScoreAnswer: Sendable, Hashable, Codable {
    public var score: Double
    /// Each level number, as a string, mapped back to its description.
    public var legend: [String: String]
    public var probabilities: [String: Double]
    public var confidence: Double

    public init(score: Double, legend: [String: String], probabilities: [String: Double], confidence: Double) {
        self.score = score
        self.legend = legend
        self.probabilities = probabilities
        self.confidence = confidence
    }
}

/// One answer, of the type its question asked for.
public enum TypeSafeAnswer: Sendable, Hashable {
    case choice(TypeSafeChoiceAnswer)
    /// The probability that the answer is yes. A Noul has no separate confidence.
    case noul(Double)
    case score(TypeSafeScoreAnswer)
}

public struct TypeSafeUsage: Sendable, Hashable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// What TypeSafe answered, already checked against the questions MacUp asked.
public struct TypeSafeResponse: Sendable, Hashable {
    /// The versioned model that answered, such as `jev-1.13.0`. Display-safe.
    public var model: String
    public var answers: [String: TypeSafeAnswer]
    public var usage: TypeSafeUsage?

    public init(model: String, answers: [String: TypeSafeAnswer], usage: TypeSafeUsage? = nil) {
        self.model = model
        self.answers = answers
        self.usage = usage
    }

    public func choice(_ id: String) -> TypeSafeChoiceAnswer? {
        if case .choice(let answer)? = answers[id] { return answer }
        return nil
    }

    public func noul(_ id: String) -> Double? {
        if case .noul(let probability)? = answers[id] { return probability }
        return nil
    }

    public func score(_ id: String) -> TypeSafeScoreAnswer? {
        if case .score(let answer)? = answers[id] { return answer }
        return nil
    }

    /// Probabilities are rounded by TypeSafe, so they are allowed to add up to
    /// a little more or less than one; nothing wider.
    static let sumTolerance = 0.05
    static let rangeTolerance = 1e-6

    /// Reads a response body and checks it against `request`.
    ///
    /// Every question must have exactly one answer of its own type; a Choice
    /// must name one of the options MacUp offered, give probabilities only for
    /// those options, and choose the most probable one; every probability and
    /// confidence must be a number between 0 and 1. Fields MacUp does not use
    /// are ignored, as they are in provider output. Anything else is
    /// ``AIError/Kind/unexpectedResponse``, and none of the answer is used.
    public static func decode(_ data: Data, for request: TypeSafeRequest) throws -> TypeSafeResponse {
        guard let root = JSONValue.parse(data)?.objectValue,
              let model = root["model"]?.stringValue,
              !model.isEmpty, model.count <= 128,
              let answers = root["answers"]?.objectValue
        else { throw AIError.unexpectedResponse }

        // An answer to a question MacUp did not ask means the reply is not
        // about this request.
        guard Set(answers.keys).isSubset(of: Set(request.questions.keys)) else { throw AIError.unexpectedResponse }

        var decoded: [String: TypeSafeAnswer] = [:]
        for (id, question) in request.questions {
            guard let answer = answers[id]?.objectValue,
                  answer["type"]?.stringValue == question.kind.rawValue
            else { throw AIError.unexpectedResponse }
            switch question.kind {
            case .choice:
                decoded[id] = .choice(try choice(answer, offered: question.optionKeys))
            case .noul:
                guard let value = number(answer["noul"]), isProbability(value) else { throw AIError.unexpectedResponse }
                decoded[id] = .noul(clamped(value))
            case .score:
                decoded[id] = .score(try score(answer, levels: question.levels.count))
            }
        }

        return TypeSafeResponse(
            model: TerminalText.sanitize(model),
            answers: decoded,
            usage: try usage(root["usage"])
        )
    }

    private static func choice(_ answer: [String: JSONValue], offered: [String]) throws -> TypeSafeChoiceAnswer {
        guard let choice = answer["choice"]?.stringValue, offered.contains(choice),
              let confidence = number(answer["confidence"]), isProbability(confidence)
        else { throw AIError.unexpectedResponse }
        let probabilities = try distribution(answer["probabilities"], allowed: Set(offered))
        // The chosen option is documented as the most probable one. A reply
        // that picks something else is contradicting itself.
        let highest = probabilities.values.max() ?? 0
        guard (probabilities[choice] ?? 0) >= highest - 0.01 else { throw AIError.unexpectedResponse }
        return TypeSafeChoiceAnswer(choice: choice, probabilities: probabilities, confidence: clamped(confidence))
    }

    private static func score(_ answer: [String: JSONValue], levels: Int) throws -> TypeSafeScoreAnswer {
        guard let score = number(answer["score"]),
              score >= -rangeTolerance, score <= Double(levels - 1) + rangeTolerance,
              let confidence = number(answer["confidence"]), isProbability(confidence)
        else { throw AIError.unexpectedResponse }
        let levelKeys = Set((0..<levels).map(String.init))
        let probabilities = try distribution(answer["probabilities"], allowed: levelKeys)
        guard let legendObject = answer["legend"]?.objectValue else { throw AIError.unexpectedResponse }
        var legend: [String: String] = [:]
        for (level, description) in legendObject {
            guard levelKeys.contains(level), let text = description.stringValue else { throw AIError.unexpectedResponse }
            legend[level] = TerminalText.sanitize(text)
        }
        return TypeSafeScoreAnswer(
            score: min(max(score, 0), Double(levels - 1)),
            legend: legend,
            probabilities: probabilities,
            confidence: clamped(confidence)
        )
    }

    /// A probability for some or all of `allowed`, and for nothing else.
    /// Missing options count as zero; they cannot change which option won.
    private static func distribution(_ value: JSONValue?, allowed: Set<String>) throws -> [String: Double] {
        guard let object = value?.objectValue, !object.isEmpty else { throw AIError.unexpectedResponse }
        var result: [String: Double] = [:]
        for (option, value) in object {
            guard allowed.contains(option), let probability = number(value), isProbability(probability) else {
                throw AIError.unexpectedResponse
            }
            result[option] = clamped(probability)
        }
        let sum = result.values.reduce(0, +)
        guard abs(sum - 1) <= sumTolerance else { throw AIError.unexpectedResponse }
        return result
    }

    private static func usage(_ value: JSONValue?) throws -> TypeSafeUsage? {
        guard let value, !value.isNull else { return nil }
        guard let object = value.objectValue,
              let input = count(object["input_tokens"]),
              let output = count(object["output_tokens"])
        else { throw AIError.unexpectedResponse }
        return TypeSafeUsage(inputTokens: input, outputTokens: output)
    }

    private static func number(_ value: JSONValue?) -> Double? {
        guard case .number(let number)? = value, number.isFinite else { return nil }
        return number
    }

    private static func count(_ value: JSONValue?) -> Int? {
        guard let number = number(value), number >= 0, number <= 1e9, number == number.rounded() else { return nil }
        return Int(number)
    }

    private static func isProbability(_ value: Double) -> Bool {
        value >= -rangeTolerance && value <= 1 + rangeTolerance
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
