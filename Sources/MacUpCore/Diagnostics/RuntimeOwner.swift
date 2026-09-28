import Foundation

/// Which tool an executable on `PATH` appears to belong to, judged from its
/// path and from what its symlinks resolve to.
///
/// These are hints for explaining a machine, exactly like ``NodeManager``.
/// Nothing here decides what MacUp executes.
struct RuntimeOwner: Sendable, Hashable {
    var displayName: String
    /// Whether the executable lives inside mise's own installs or shims.
    var isMiseManaged: Bool

    static let unrecognized = RuntimeOwner(displayName: NodeManager.unknown.displayName, isMiseManaged: false)

    var isRecognized: Bool { displayName != NodeManager.unknown.displayName }

    /// How to name the owner mid-sentence. An unrecognized installation is
    /// described as one rather than attributed to a tool called
    /// "unrecognized".
    var attribution: String {
        isRecognized ? "installed by \(displayName)" : "from an installation MacUp does not recognize"
    }

    /// Names a runtime executable's owner.
    ///
    /// Node has a dedicated classifier because so many tools install it, and
    /// because npm's global packages hang off whichever Node wins; every other
    /// runtime is judged by the locations the common managers use.
    static func identify(
        tool: String,
        path: String,
        canonicalPath: String,
        homeDirectory: String,
        miseDataDirectory: String,
        homebrewPrefix: String?
    ) -> RuntimeOwner {
        let mise = isUnderMise(path: path, canonicalPath: canonicalPath, miseDataDirectory: miseDataDirectory)
        if RuntimeCatalog.baseName(tool) == "node" || RuntimeCatalog.baseName(tool) == "nodejs" {
            let manager = NodeManager.classify(
                path: path,
                canonicalPath: canonicalPath,
                homeDirectory: homeDirectory,
                miseDataDirectory: miseDataDirectory
            )
            return RuntimeOwner(displayName: manager.displayName, isMiseManaged: mise || manager == .mise)
        }
        if mise { return RuntimeOwner(displayName: NodeManager.mise.displayName, isMiseManaged: true) }
        for candidate in [canonicalPath, path] {
            if let name = manager(of: candidate, homeDirectory: homeDirectory, homebrewPrefix: homebrewPrefix) {
                return RuntimeOwner(displayName: name, isMiseManaged: false)
            }
        }
        return .unrecognized
    }

    static func isUnderMise(path: String, canonicalPath: String, miseDataDirectory: String) -> Bool {
        [canonicalPath, path].contains { candidate in
            candidate.hasPrefix(miseDataDirectory + "/installs/") || candidate.hasPrefix(miseDataDirectory + "/shims/")
        }
    }

    private static func manager(of candidate: String, homeDirectory: String, homebrewPrefix: String?) -> String? {
        if candidate.contains("/Cellar/") { return "Homebrew" }
        if let homebrewPrefix, candidate.hasPrefix(homebrewPrefix + "/") { return "Homebrew" }
        if candidate.hasPrefix("/usr/bin/") || candidate.hasPrefix("/System/") { return "macOS" }
        if candidate.hasPrefix("/Library/Frameworks/Python.framework/") { return "the python.org installer" }
        if candidate.hasPrefix(homeDirectory + "/.pyenv/") { return "pyenv" }
        if candidate.hasPrefix(homeDirectory + "/.rbenv/") { return "rbenv" }
        if candidate.contains("/.rvm/rubies/") { return "RVM" }
        if candidate.hasPrefix(homeDirectory + "/.asdf/") { return "asdf" }
        if candidate.contains("/miniconda") || candidate.contains("/anaconda") { return "conda" }
        if candidate.hasPrefix(homeDirectory + "/.cargo/") || candidate.hasPrefix(homeDirectory + "/.rustup/") { return "rustup" }
        return nil
    }
}

/// The runtimes Doctor compares across `PATH`.
///
/// Kept to the ones where macOS, Homebrew, and a version manager commonly
/// provide the same command, which is where developers actually get confused
/// about ownership (CLAUDE.md §13). A tool that is not listed is left alone
/// rather than matched to a guessed executable name.
enum RuntimeExecutables {
    private static let names: [String: [String]] = [
        "node": ["node"],
        "nodejs": ["node"],
        "python": ["python3", "python"],
        "ruby": ["ruby"],
    ]

    /// The executables a runtime installs, in the order a shell would find
    /// them, or an empty list when MacUp does not know.
    static func forTool(_ tool: String) -> [String] {
        names[RuntimeCatalog.baseName(tool)] ?? []
    }
}
