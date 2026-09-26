import OSLog

/// OSLog categories from CLAUDE.md §17.
///
/// Interpolated values are private by default in OSLog. Never log complete
/// environments, command output, or anything that has not passed through
/// ``Redactor``.
public enum Log {
    public static let core = Logger(subsystem: MacUp.identifier, category: "core")
    public static let discovery = Logger(subsystem: MacUp.identifier, category: "discovery")
    public static let policy = Logger(subsystem: MacUp.identifier, category: "policy")
    public static let planning = Logger(subsystem: MacUp.identifier, category: "planning")
    public static let execution = Logger(subsystem: MacUp.identifier, category: "execution")
    public static let homebrew = Logger(subsystem: MacUp.identifier, category: "homebrew")
    public static let npm = Logger(subsystem: MacUp.identifier, category: "npm")
    public static let mise = Logger(subsystem: MacUp.identifier, category: "mise")
    public static let macos = Logger(subsystem: MacUp.identifier, category: "macos")
    public static let doctor = Logger(subsystem: MacUp.identifier, category: "doctor")
    public static let scheduler = Logger(subsystem: MacUp.identifier, category: "scheduler")
}
