import Foundation

/// Which tool installed a Node.js executable, judged from its path.
///
/// These are hints, not certainties: they are shown as ownership information
/// and never used to decide what to execute.
public enum NodeManager: String, Sendable, Hashable, Codable, CaseIterable {
    case mise
    case homebrew
    case nvm
    case volta
    case fnm
    case asdf
    case nodenv
    case n
    case unknown

    public var displayName: String {
        switch self {
        case .mise: "mise"
        case .homebrew: "Homebrew"
        case .nvm: "nvm"
        case .volta: "Volta"
        case .fnm: "fnm"
        case .asdf: "asdf"
        case .nodenv: "nodenv"
        case .n: "n"
        case .unknown: "an unrecognized installation"
        }
    }

    /// Classifies a node executable by its path and symlink target.
    static func classify(path: String, canonicalPath: String, homeDirectory: String, miseDataDirectory: String) -> NodeManager {
        for candidate in [canonicalPath, path] {
            if candidate.hasPrefix(miseDataDirectory + "/installs/") || candidate.hasPrefix(miseDataDirectory + "/shims/") {
                return .mise
            }
            if candidate.contains("/Cellar/node") || candidate.contains("/opt/homebrew/opt/node") || candidate.contains("/usr/local/opt/node") {
                return .homebrew
            }
            if candidate.hasPrefix(homeDirectory + "/.nvm/versions/node/") { return .nvm }
            if candidate.hasPrefix(homeDirectory + "/.volta/") { return .volta }
            if candidate.contains("/fnm/node-versions/") || candidate.contains("/fnm_multishells/") { return .fnm }
            if candidate.hasPrefix(homeDirectory + "/.asdf/") { return .asdf }
            if candidate.hasPrefix(homeDirectory + "/.nodenv/versions/") { return .nodenv }
            if candidate.hasPrefix("/usr/local/n/versions/") || candidate.hasPrefix(homeDirectory + "/n/versions/") { return .n }
        }
        return .unknown
    }

    /// mise's data directory, following mise's own environment variables.
    static func miseDataDirectory(environment: [String: String], homeDirectory: String) -> String {
        if let explicit = environment["MISE_DATA_DIR"], explicit.hasPrefix("/") {
            return PathDisplay.standardized(explicit)
        }
        if let xdg = environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            return PathDisplay.standardized(xdg) + "/mise"
        }
        return homeDirectory + "/.local/share/mise"
    }
}
