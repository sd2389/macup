import Foundation

extension MacUpConfiguration {
    /// Optional AI help from TypeSafe (docs/TRUST_AND_SECURITY.md, "The
    /// opt-in AI boundary").
    ///
    /// Off unless the user turns it on, and while it is off MacUp sends
    /// nothing anywhere. The section is absent from a configuration file until
    /// the user first changes it, so a MacUp that never uses AI writes the
    /// same file it always did. The API key is never kept here.
    public struct AISettings: Sendable, Hashable, Codable {
        public static let defaultModel = "jev-latest"

        /// Whether MacUp may send the requests the user asks for.
        public var enabled: Bool
        /// The TypeSafe model to ask, such as `jev-latest` or a versioned
        /// `jev-1.13.0` to keep answers from moving under a threshold.
        public var model: String

        public init(enabled: Bool = false, model: String = AISettings.defaultModel) {
            self.enabled = enabled
            self.model = model
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.defaultModel
        }

        /// A model name is sent in every request, so it is held to the shape
        /// TypeSafe's names have: letters, digits, dots, dashes, underscores.
        public static func isValidModelName(_ name: String) -> Bool {
            guard (1...64).contains(name.count), let first = name.unicodeScalars.first,
                  first.isASCII, CharacterSet.alphanumerics.contains(first)
            else { return false }
            return name.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
            }
        }
    }

    /// The AI settings in effect: the file's own, or off.
    public var aiSettings: AISettings { ai ?? AISettings() }
}

extension ConfigurationValidator {
    static let aiKeys: Set<String> = ["enabled", "model"]

    /// Problems with the `ai` section. Any of them keeps AI help off, like
    /// every error keeps automatic modification off.
    static func aiIssues(in configuration: MacUpConfiguration) -> [ConfigurationIssue] {
        guard let ai = configuration.ai, !MacUpConfiguration.AISettings.isValidModelName(ai.model) else { return [] }
        return [ConfigurationIssue(
            .error,
            "ai.model",
            "Use a TypeSafe model name such as \(MacUpConfiguration.AISettings.defaultModel): letters, digits, dots, dashes, or underscores; found '\(TerminalText.sanitize(ai.model))'."
        )]
    }
}
