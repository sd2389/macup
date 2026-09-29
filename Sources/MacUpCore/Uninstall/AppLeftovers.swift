import Foundation

/// Something an uninstall found that belongs to what is being removed, before
/// it is measured and checked against the boundary.
struct Leftover: Sendable, Hashable {
    var path: String
    var category: LeftoverCategory
    var selectedByDefault: Bool
    var reason: String
    var warning: String?
}

/// The files an app leaves in the home folder's Library, found by fixed
/// rules and never by resemblance (docs/TRUST_AND_SECURITY.md, "Uninstall"):
///
/// - **Belongs to the app** (ticked): in Caches, Preferences (and its
///   ByHost folder), Saved Application State, HTTPStorages, WebKit, Logs,
///   Cookies, Application Scripts, and LaunchAgents, an entry whose name is
///   the bundle identifier or starts with it and a dot — `com.openai.chat.plist`,
///   `com.openai.chat.savedState` — and a launch agent whose label follows
///   the same rule or whose program is inside the app.
/// - **App data** (not ticked): Application Support and Containers entries
///   by the same rule, and a Group Containers entry whose name is the
///   developer's team identifier, a dot, and the bundle identifier.
/// - **Matched by name** (not ticked): a folder named exactly like the app
///   in Application Support, Caches, or Logs.
///
/// A name that belongs to a longer bundle identifier of another installed
/// app — `com.google.Chrome.canary` when uninstalling `com.google.Chrome` —
/// is left to that app.
struct AppLeftoverScanner: Sendable {
    var homeDirectory: String
    var otherBundleIdentifiers: Set<String>

    static let ownFolders = [
        "Caches", "Preferences", "Preferences/ByHost", "Saved Application State", "HTTPStorages", "WebKit", "Logs",
        "Cookies", "Application Scripts", "LaunchAgents",
    ]
    static let dataFolders = ["Application Support", "Containers"]
    static let nameFolders = ["Application Support", "Caches", "Logs"]

    static let dataWarning = "Your chats, saved games, and settings in this app."

    var library: String { homeDirectory + "/Library" }

    func scan(bundleIdentifier: String?, bundlePath: String, names: [String], teamIdentifier: String?) -> [Leftover] {
        var found: [Leftover] = []
        if let identifier = bundleIdentifier {
            for folder in Self.ownFolders {
                for name in matching(identifier, in: library + "/" + folder) {
                    found.append(Leftover(
                        path: library + "/" + folder + "/" + name,
                        category: .belongsToApp,
                        selectedByDefault: true,
                        reason: "Named after \(identifier), the app's bundle identifier."
                    ))
                }
            }
            for folder in Self.dataFolders {
                for name in matching(identifier, in: library + "/" + folder) {
                    found.append(Leftover(
                        path: library + "/" + folder + "/" + name,
                        category: .appData,
                        selectedByDefault: false,
                        reason: "Named after \(identifier), the app's bundle identifier.",
                        warning: Self.dataWarning
                    ))
                }
            }
            if let team = teamIdentifier {
                for name in matching(team + "." + identifier, in: library + "/Group Containers") {
                    found.append(Leftover(
                        path: library + "/Group Containers/" + name,
                        category: .appData,
                        selectedByDefault: false,
                        reason: "Shared by the apps of \(team), the developer who signed this app, and named after its bundle identifier.",
                        warning: Self.dataWarning
                    ))
                }
            }
        }
        found += launchAgents(bundleIdentifier: bundleIdentifier, bundlePath: bundlePath, alreadyFound: Set(found.map(\.path)))
        for name in names where name != "." && name != ".." {
            for folder in Self.nameFolders {
                let path = library + "/" + folder + "/" + name
                guard FileTree.isDirectory(path), !found.contains(where: { $0.path == path }) else { continue }
                found.append(Leftover(
                    path: path,
                    category: .matchedByName,
                    selectedByDefault: false,
                    reason: "Named “\(name)”, like the app. Matched by name only; check before removing.",
                    warning: folder == "Application Support" ? Self.dataWarning : nil
                ))
            }
        }
        return found
    }

    /// Names in `directory` that are `identifier` or start with it and a dot,
    /// less those that belong to a longer identifier of another app.
    func matching(_ identifier: String, in directory: String) -> [String] {
        (FileTree.names(in: directory) ?? []).filter { Self.name($0, belongsTo: identifier, notTo: otherBundleIdentifiers) }
    }

    static func name(_ name: String, belongsTo identifier: String, notTo others: Set<String>) -> Bool {
        guard name == identifier || name.hasPrefix(identifier + ".") else { return false }
        return !others.contains { other in
            other != identifier && other.hasPrefix(identifier + ".") && (name == other || name.hasPrefix(other + "."))
        }
    }

    /// Launch agents in the home folder that start this app: by label, or by
    /// a program inside the bundle.
    private func launchAgents(bundleIdentifier: String?, bundlePath: String, alreadyFound: Set<String>) -> [Leftover] {
        let directory = library + "/LaunchAgents"
        let bundle = FileTree.canonicalPath(bundlePath) ?? bundlePath
        var found: [Leftover] = []
        for name in FileTree.names(in: directory) ?? [] where name.hasSuffix(".plist") {
            let path = directory + "/" + name
            guard !alreadyFound.contains(path), let agent = LaunchAgentFile(path: path) else { continue }
            if let identifier = bundleIdentifier, let label = agent.label,
               Self.name(label, belongsTo: identifier, notTo: otherBundleIdentifiers) {
                found.append(Leftover(
                    path: path,
                    category: .belongsToApp,
                    selectedByDefault: true,
                    reason: "A launch agent labelled \(label), after the app's bundle identifier. It stops loading at your next login."
                ))
            } else if agent.startsProgram(inside: bundle) {
                found.append(Leftover(
                    path: path,
                    category: .belongsToApp,
                    selectedByDefault: true,
                    reason: "A launch agent that starts a program inside \((bundlePath as NSString).lastPathComponent). It stops loading at your next login."
                ))
            }
        }
        return found
    }
}

/// What a launchd property list says it runs, read without trusting it.
struct LaunchAgentFile: Sendable, Hashable {
    var label: String?
    var program: String?

    init?(path: String) {
        guard let plist = FileTree.propertyList(path, maximumBytes: 256 * 1024) else { return nil }
        label = (plist["Label"] as? String).flatMap { AppScanner.usableIdentifier($0) }
        program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
    }

    /// Whether the program it starts lives inside `bundle` (canonical).
    func startsProgram(inside bundle: String) -> Bool {
        guard let program, program.hasPrefix("/") else { return false }
        let resolved = FileTree.canonicalPath(program) ?? (program as NSString).standardizingPath
        return FileTree.isInside(resolved, bundle) || FileTree.isInside((program as NSString).standardizingPath, bundle)
    }
}
