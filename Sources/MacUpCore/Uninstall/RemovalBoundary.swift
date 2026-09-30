import Foundation

/// Where an uninstall may remove files, decided from the path alone.
///
/// A whitelist, checked against where an item really lives — its parent with
/// every link resolved (``FileTree/canonicalLocation(_:)``). An item is
/// removable only strictly inside an allowed folder, and never when it is one
/// of the folders a Mac is built around: the home folder, `~/Library`, any
/// folder directly in `~/Library`, the Trash, the standard folders of the home
/// folder, or anything under `/System`, `/usr`, `/bin`, `/sbin`, or `/private`.
/// The only ways past those are the two MacUp can name exactly: a Homebrew
/// formula's own `var` and `etc` folders, and MacUp's own command when MacUp
/// is uninstalling itself.
///
/// A refusal is a reason, not a correction: a path the boundary refuses is
/// skipped and reported, never trimmed or adjusted into one it would allow.
public struct RemovalBoundary: Sendable, Hashable {
    public var homeDirectory: String
    /// Folders whose contents may be removed. Never the folder itself.
    public var roots: [String]
    /// Folders in which only an app bundle may be removed: `Name.app`, or
    /// `Folder/Name.app` one level down.
    public var applicationDirectories: [String]
    /// Paths that are never removed, wherever they are.
    public var protectedPaths: Set<String>
    /// Folders whose direct children are never removed: `~/Library`, whose
    /// children are its top-level folders, and iCloud Drive's folder.
    public var protectedChildrenOf: [String]
    /// Nothing inside these is removed, apart from the Homebrew areas and
    /// ``exactFiles``.
    public var systemPrefixes: [String]
    /// Inside a Homebrew installation only a formula's data and settings —
    /// what is inside `var` and `etc` — may be removed. Homebrew removes
    /// everything else it installed itself.
    public var homebrewPrefix: String?
    /// Single files that may be removed outside the roots: MacUp's own
    /// command, and only when MacUp is uninstalling itself.
    public var exactFiles: Set<String>

    public init(
        homeDirectory: String,
        roots: [String],
        applicationDirectories: [String],
        protectedPaths: Set<String>,
        protectedChildrenOf: [String],
        systemPrefixes: [String],
        homebrewPrefix: String? = nil,
        exactFiles: Set<String> = []
    ) {
        self.homeDirectory = homeDirectory
        self.roots = roots
        self.applicationDirectories = applicationDirectories
        self.protectedPaths = protectedPaths
        self.protectedChildrenOf = protectedChildrenOf
        self.systemPrefixes = systemPrefixes
        self.homebrewPrefix = homebrewPrefix
        self.exactFiles = exactFiles
    }

    /// The folders of a home folder that hold a person's own work or a Mac's
    /// setup. They are protected themselves; what is inside them is judged
    /// like anything else.
    public static let standardHomeFolders = [
        "Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
        "Sites", ".Trash", ".config", ".local", ".local/bin", ".local/share", ".local/state", ".cache", ".ssh",
        ".gnupg", ".zshrc", ".bashrc", ".bash_profile", ".profile", ".zprofile",
    ]

    /// Where nothing is removed on a real Mac.
    public static let standardSystemPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/private", "/Library", "/etc", "/var", "/tmp", "/dev", "/cores",
        "/opt", "/Volumes", "/Network",
    ]

    /// The boundary for this Mac.
    public static func standard(
        homeDirectory: String,
        applicationDirectories: [String],
        systemPrefixes: [String] = RemovalBoundary.standardSystemPrefixes,
        homebrewPrefix: String? = nil,
        exactFiles: Set<String> = []
    ) -> RemovalBoundary {
        let home = PathDisplay.standardized(homeDirectory)
        var protected = Set(standardHomeFolders.map { home + "/" + $0 })
        protected.formUnion([home, "/", "/Users", "/Applications", "/Library", "/System"])
        protected.formUnion(applicationDirectories)
        return RemovalBoundary(
            homeDirectory: home,
            roots: [home],
            applicationDirectories: applicationDirectories,
            protectedPaths: protected,
            protectedChildrenOf: [home + "/Library", home + "/Library/Mobile Documents"],
            systemPrefixes: systemPrefixes,
            homebrewPrefix: homebrewPrefix,
            exactFiles: exactFiles
        )
    }

    public var trashDirectory: String { homeDirectory + "/.Trash" }

    /// Why the item at `path` may not be removed, or `nil` when it may.
    /// `path` is where the item really lives: its canonical location.
    public func refusal(for path: String) -> String? {
        guard FileTree.isPlainAbsolute(path) else {
            return "it is not a plain, absolute path"
        }
        if FileTree.isWithin(path, trashDirectory) {
            return "it is in the Trash"
        }
        if protectedPaths.contains(path) {
            return "it is a folder MacUp never removes"
        }
        let parent = (path as NSString).deletingLastPathComponent
        if let folder = protectedChildrenOf.first(where: { $0 == path || $0 == parent }) {
            return "it is a top-level folder of \(PathDisplay.abbreviatingHome(folder, homeDirectory: homeDirectory)), which MacUp never removes"
        }
        // MacUp's own command, by its exact path: `make install
        // PREFIX=/usr/local` puts it inside Intel Homebrew's prefix.
        if exactFiles.contains(path) { return nil }
        if let prefix = usableHomebrewPrefix, FileTree.isWithin(path, prefix) {
            let areas = [prefix + "/var", prefix + "/etc"]
            return areas.contains(where: { FileTree.isInside(path, $0) })
                ? nil
                : "it is part of Homebrew's own installation, which Homebrew removes itself"
        }
        if let prefix = systemPrefixes.first(where: { FileTree.isWithin(path, $0) }) {
            return "it is inside \(prefix), which MacUp never changes"
        }
        if let directory = applicationDirectories.first(where: { FileTree.isInside(path, $0) }) {
            return isAppBundle(path, in: directory)
                ? nil
                : "it is not an app in \(PathDisplay.abbreviatingHome(directory, homeDirectory: homeDirectory))"
        }
        if roots.contains(where: { FileTree.isInside(path, $0) }) { return nil }
        return "it is outside the folders MacUp removes from"
    }

    /// The Homebrew prefix, when it is one MacUp can reason about: a plain
    /// path that is not the root of the disk, a system folder, or a folder
    /// MacUp protects. A prefix Homebrew reported as `/` would otherwise make
    /// every `/var` and `/etc` removable.
    public var usableHomebrewPrefix: String? {
        guard let prefix = homebrewPrefix, FileTree.isPlainAbsolute(prefix), !protectedPaths.contains(prefix),
              !systemPrefixes.contains(prefix), !roots.contains(prefix)
        else { return nil }
        return prefix
    }

    private func isAppBundle(_ path: String, in directory: String) -> Bool {
        guard path.hasSuffix(".app") else { return false }
        let relative = path.dropFirst(directory.count + 1).split(separator: "/")
        switch relative.count {
        case 1: return true
        case 2: return !relative[0].hasSuffix(".app")
        default: return false
        }
    }
}
