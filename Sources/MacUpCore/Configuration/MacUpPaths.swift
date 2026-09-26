/// Where MacUp keeps its files. The CLI and the app share one canonical scheme:
///
/// - configuration: `~/.config/macup/config.json`
/// - state (history, logs): `~/.local/state/macup/`
///
/// `MACUP_CONFIG_DIR` and `MACUP_STATE_DIR` override the directories with
/// absolute paths. They exist for testing and experiments; an app launched
/// from Finder does not see shell variables, so the default scheme is the
/// source of truth.
public struct MacUpPaths: Sendable, Hashable, Codable {
    public enum Source: String, Sendable, Hashable, Codable {
        case standard
        case environment
    }

    public static let configDirectoryVariable = "MACUP_CONFIG_DIR"
    public static let stateDirectoryVariable = "MACUP_STATE_DIR"

    public var configDirectory: String
    public var stateDirectory: String
    public var configDirectorySource: Source
    public var stateDirectorySource: Source

    public init(
        configDirectory: String,
        stateDirectory: String,
        configDirectorySource: Source = .standard,
        stateDirectorySource: Source = .standard
    ) {
        self.configDirectory = configDirectory
        self.stateDirectory = stateDirectory
        self.configDirectorySource = configDirectorySource
        self.stateDirectorySource = stateDirectorySource
    }

    public var configFile: String { configDirectory + "/config.json" }
    public var historyFile: String { stateDirectory + "/history.jsonl" }

    /// Resolves the paths for a user. Throws `configurationInvalid` when an
    /// override is not an absolute path, rather than guessing what was meant.
    public static func resolve(homeDirectory: String, environment: [String: String]) throws -> MacUpPaths {
        let home = PathDisplay.standardized(homeDirectory)
        let config = try override(configDirectoryVariable, in: environment)
        let state = try override(stateDirectoryVariable, in: environment)
        return MacUpPaths(
            configDirectory: config ?? home + "/.config/macup",
            stateDirectory: state ?? home + "/.local/state/macup",
            configDirectorySource: config == nil ? .standard : .environment,
            stateDirectorySource: state == nil ? .standard : .environment
        )
    }

    private static func override(_ variable: String, in environment: [String: String]) throws -> String? {
        guard let value = environment[variable], !value.isEmpty else { return nil }
        guard value.hasPrefix("/"), !value.unicodeScalars.contains(where: TerminalText.isUnsafe) else {
            throw MacUpError(
                .configurationInvalid,
                "\(variable) must be an absolute path.",
                recoverySuggestion: "Unset \(variable) or set it to an absolute directory path."
            )
        }
        return PathDisplay.standardized(value)
    }
}
