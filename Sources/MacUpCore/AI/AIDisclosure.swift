import Foundation

/// Exactly what each AI feature sends, shown before AI help is turned on and
/// whenever the user asks ("What MacUp sends").
///
/// The lists are the contract. Each feature's request builder sends these
/// fields and nothing else, and its tests read the body MacUp built and check
/// it against them. How TypeSafe handles what it receives, retention
/// included, is TypeSafe's to state, so MacUp links its Data Processing
/// Agreement rather than paraphrasing it.
public struct AIDisclosure: Sendable, Hashable, Codable {
    public struct Feature: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        public var title: String
        /// When a request is made. Always something the user did.
        public var when: String
        public var sends: [String]

        public init(id: String, title: String, when: String, sends: [String]) {
            self.id = id
            self.title = title
            self.when = when
            self.sends = sends
        }
    }

    public var recipient: String
    public var features: [Feature]
    public var withEveryRequest: [String]
    public var neverSent: [String]
    public var dataProcessingAgreement: URL

    public static let standard = AIDisclosure(
        recipient: "TypeSafe, at \(TypeSafeEndpoint.host)",
        features: [
            Feature(
                id: "ask",
                title: "Ask MacUp",
                when: "Only when you ask something with `macup ask` or the Ask MacUp field.",
                sends: [
                    "What you typed, at most \(AskMacUp.maximumRequestLength) characters, after MacUp removes anything that looks like a secret and shortens your home folder to ~",
                    "The IDs and names of packages MacUp found on this Mac, each with its package manager, for example brew:mysql (mysql, Homebrew formula): at most \(AskMacUp.maximumItemOptions)",
                    "MacUp's fixed questions and their answer choices, which name the four package managers and the four policies",
                ]
            ),
            Feature(
                id: "estimate",
                title: "AI caution for updates",
                when: "Only when you ask about an update with `macup insight` or the Ask TypeSafe button beside it. The answer is kept on this Mac, so the same update is not sent twice.",
                sends: [
                    "The update's package ID and name, for example brew:mysql",
                    "Its package manager and kind, for example Homebrew formula",
                    "The installed and available versions, for example 8.4.3 and 9.1.0",
                ]
            ),
            Feature(
                id: "test",
                title: "Connection test",
                when: "Only when you run `macup ai test` or press Test Connection.",
                sends: ["A fixed sentence and one fixed question. Nothing about your Mac."]
            ),
        ],
        withEveryRequest: [
            "Your TypeSafe API key, in the Authorization header, to \(TypeSafeEndpoint.host) only",
            "The model name from your configuration (\(MacUpConfiguration.AISettings.defaultModel) unless you changed it)",
            "MacUp's name and version, in place of the operating system details macOS would otherwise add",
        ],
        neverSent: [
            "Environment variables",
            "File paths, including your home folder and user name",
            "The contents of any file, including MacUp's configuration",
            "Shell history",
            "Passwords, tokens, or keys other than your TypeSafe key",
            "Anything in the background: every request is one you asked for",
        ],
        dataProcessingAgreement: TypeSafeEndpoint.dataProcessingAgreement
    )
}
