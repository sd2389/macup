/// Where MacUp keeps its files. The CLI and the app share one canonical scheme:
///
/// - configuration: `~/.config/macup/config.json`
/// - state (history, logs, last scheduled check): `~/.local/state/macup/`
/// - the scheduled-check launchd agent: `~/Library/LaunchAgents/`
///
/// `MACUP_CONFIG_DIR`, `MACUP_STATE_DIR`, and `MACUP_LAUNCH_AGENTS_DIR`
/// override the directories with absolute paths. They exist for testing and
/// experiments; an app launched from Finder does not see shell variables, so
/// the default scheme is the source of truth.
public struct MacUpPaths: Sendable, Hashable, Codable {
    public enum Source: String, Sendable, Hashable, Codable {
        case standard
        case environment
    }

    public static let configDirectoryVariable = "MACUP_CONFIG_DIR"
    public static let stateDirectoryVariable = "MACUP_STATE_DIR"
    public static let launchAgentsDirectoryVariable = "MACUP_LAUNCH_AGENTS_DIR"

    public var configDirectory: String
    public var stateDirectory: String
    public var launchAgentsDirectory: String
    public var configDirectorySource: Source
    public var stateDirectorySource: Source
    public var launchAgentsDirectorySource: Source

    public init(
        configDirectory: String,
        stateDirectory: String,
        launchAgentsDirectory: String,
        configDirectorySource: Source = .standard,
        stateDirectorySource: Source = .standard,
        launchAgentsDirectorySource: Source = .standard
    ) {
        self.configDirectory = configDirectory
        self.stateDirectory = stateDirectory
        self.launchAgentsDirectory = launchAgentsDirectory
        self.configDirectorySource = configDirectorySource
        self.stateDirectorySource = stateDirectorySource
        self.launchAgentsDirectorySource = launchAgentsDirectorySource
    }

    public var configFile: String { configDirectory + "/config.json" }
    public var historyFile: String { stateDirectory + "/history.jsonl" }
    /// The report written by `macup check --save-state`, which is how a
    /// scheduled check leaves its result behind.
    public var lastCheckFile: String { stateDirectory + "/" + Self.lastCheckFileName }
    public static let lastCheckFileName = "last-check.json"
    /// Where launchd sends the scheduled check's diagnostics.
    public var schedulerLogFile: String { stateDirectory + "/scheduler.log" }

    /// The default scheme for a user, with no overrides applied. One place to
    /// change it, so the CLI and the app cannot drift apart.
    public static func standard(homeDirectory: String) -> MacUpPaths {
        let home = PathDisplay.standardized(homeDirectory)
        return MacUpPaths(
            configDirectory: home + "/.config/macup",
            stateDirectory: home + "/.local/state/macup",
            launchAgentsDirectory: home + "/Library/LaunchAgents"
        )
    }

    /// Resolves the paths for a user. Throws `configurationInvalid` when an
    /// override is not an absolute path, rather than guessing what was meant.
    public static func resolve(homeDirectory: String, environment: [String: String]) throws -> MacUpPaths {
        let home = PathDisplay.standardized(homeDirectory)
        let config = try override(configDirectoryVariable, in: environment)
        let state = try override(stateDirectoryVariable, in: environment)
        let agents = try override(launchAgentsDirectoryVariable, in: environment)
        let defaults = standard(homeDirectory: home)
        return MacUpPaths(
            configDirectory: config ?? defaults.configDirectory,
            stateDirectory: state ?? defaults.stateDirectory,
            launchAgentsDirectory: agents ?? defaults.launchAgentsDirectory,
            configDirectorySource: config == nil ? .standard : .environment,
            stateDirectorySource: state == nil ? .standard : .environment,
            launchAgentsDirectorySource: agents == nil ? .standard : .environment
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
