import Foundation

/// One file or folder an app that is gone left behind.
public struct OrphanedFile: Sendable, Hashable, Codable, Identifiable {
    public var path: String
    public var category: LeftoverCategory
    public var reason: String

    public init(path: String, category: LeftoverCategory, reason: String) {
        self.path = path
        self.category = category
        self.reason = reason
    }

    public var id: String { path }
}

/// Files in `~/Library` named after an app that is not installed any more:
/// what dragging an app to the Trash leaves behind.
public struct OrphanedLeftovers: Sendable, Hashable, Codable, Identifiable {
    /// The bundle identifier the files are named after.
    public var identifier: String
    /// The last part of the identifier, which is usually what the app was
    /// called: `chat` in `com.openai.chat`. A guess, and said to be one.
    public var guessedName: String
    public var files: [OrphanedFile]
    public var sizeBytes: Int64?
    public var sizeIsPartial: Bool
    /// Why MacUp believes an app, rather than a tool or a daemon, left these.
    public var evidence: [String]

    public init(
        identifier: String,
        guessedName: String,
        files: [OrphanedFile],
        sizeBytes: Int64? = nil,
        sizeIsPartial: Bool = false,
        evidence: [String] = []
    ) {
        self.identifier = identifier
        self.guessedName = guessedName
        self.files = files
        self.sizeBytes = sizeBytes
        self.sizeIsPartial = sizeIsPartial
        self.evidence = evidence
    }

    public var id: String { identifier }
    /// How it is named on the command line.
    public var target: String { OrphanScanner.targetPrefix + identifier }
    public var paths: [String] { files.map(\.path) }
}

/// Finds what apps that are no longer installed left in `~/Library`.
///
/// This is the one part of the uninstaller with nothing to ask. An installed
/// app can be read — its bundle identifier, its name, who signed it — but an
/// app that is gone can only be inferred from the files it left, so the rules
/// are deliberately narrow and everything found is reported as a guess:
///
/// - the name must be a bundle identifier with at least three parts, and not
///   in Apple's namespace, because `com.apple.…` files are macOS's own;
/// - no installed app may claim it, by its own identifier or by a longer one
///   — `com.google.Chrome.canary` belongs to Chrome Canary while Canary is
///   installed, and is an orphan only once it is not;
/// - the files must look like an app's rather than a command-line tool's: a
///   saved window state, a sandbox container, or web storage says a windowed
///   app wrote them, and settings together with an Application Support folder
///   say the same more weakly. Anything with less evidence is left out, which
///   is why this finds fewer leftovers than it could.
///
/// Nothing found here is ever ticked for the user. MacUp cannot ask an app
/// that is gone whether these are its files, so the person decides
/// (CLAUDE.md §1).
public struct OrphanScanner: Sendable {
    public static let targetPrefix = "leftovers:"

    public var homeDirectory: String

    public init(homeDirectory: String) {
        self.homeDirectory = PathDisplay.standardized(homeDirectory)
    }

    var library: String { homeDirectory + "/Library" }

    /// Where an entry named after a bundle identifier may be, what it means,
    /// and whether it is evidence that an app wrote it.
    struct Place: Sendable {
        var folder: String
        var category: LeftoverCategory
        var what: String
        /// Evidence a windowed app, rather than a tool or a daemon, left it.
        var strong: Bool = false
        /// Evidence only together with another `supporting` place.
        var supporting: Bool = false
    }

    static let places: [Place] = [
        Place(folder: "Saved Application State", category: .belongsToApp, what: "the windows it had open", strong: true),
        Place(folder: "Containers", category: .appData, what: "its sandbox container", strong: true),
        Place(folder: "WebKit", category: .belongsToApp, what: "web content it stored"),
        Place(folder: "HTTPStorages", category: .belongsToApp, what: "cookies and web storage"),
        Place(folder: "Preferences", category: .belongsToApp, what: "its settings", supporting: true),
        Place(folder: "Preferences/ByHost", category: .belongsToApp, what: "its per-Mac settings"),
        Place(folder: "Application Support", category: .appData, what: "its data", supporting: true),
        Place(folder: "Caches", category: .belongsToApp, what: "its caches"),
        Place(folder: "Logs", category: .belongsToApp, what: "its logs"),
        Place(folder: "Cookies", category: .belongsToApp, what: "its cookies"),
        Place(folder: "Application Scripts", category: .belongsToApp, what: "its scripts"),
    ]

    /// Everything left behind, biggest first.
    ///
    /// `installedIdentifiers` is every installed app's bundle identifier,
    /// plus MacUp's own; nothing named after one of them is an orphan.
    /// `measure` adds up each group's size, which reads every file in it.
    public func scan(
        installedIdentifiers: Set<String>,
        fileSystem: any FileSystem = LocalFileSystem(),
        measure: Bool = true
    ) -> [OrphanedLeftovers] {
        var byIdentifier: [String: [(file: OrphanedFile, place: Place)]] = [:]

        for place in Self.places {
            let directory = library + "/" + place.folder
            for name in FileTree.names(in: directory) ?? [] {
                guard let identifier = Self.identifier(fromEntry: name, in: place.folder),
                      !Self.isClaimed(identifier, by: installedIdentifiers)
                else { continue }
                let path = directory + "/" + name
                byIdentifier[identifier, default: []].append((
                    OrphanedFile(
                        path: path,
                        category: place.category,
                        reason: "Named after \(identifier), and \(place.what)."
                    ),
                    place
                ))
            }
        }

        var found: [OrphanedLeftovers] = []
        for (identifier, entries) in byIdentifier {
            guard let evidence = Self.evidence(for: entries.map(\.place)) else { continue }
            var group = OrphanedLeftovers(
                identifier: identifier,
                guessedName: identifier.split(separator: ".").last.map(String.init) ?? identifier,
                files: entries.map(\.file).sorted { $0.path < $1.path },
                evidence: evidence
            )
            if measure {
                let sizes = group.paths.map { FileTree.size(of: $0) }
                group.sizeBytes = sizes.compactMap { $0?.bytes }.reduce(0, +)
                group.sizeIsPartial = sizes.contains { $0 == nil || $0?.partial == true }
            }
            found.append(group)
        }
        return found.sorted {
            ($0.sizeBytes ?? 0, $1.identifier) > ($1.sizeBytes ?? 0, $0.identifier)
        }
    }

    /// The bundle identifier an entry is named after, or `nil` when the name
    /// is not one MacUp will act on.
    ///
    /// Suffixes macOS adds are removed first — `.plist`, `.savedState`,
    /// `.binarycookies`, and the per-Mac `…​.<UUID>.plist` in `ByHost` — and
    /// what is left has to be a reverse-DNS name of at least three parts
    /// outside Apple's namespace.
    static func identifier(fromEntry name: String, in folder: String) -> String? {
        var bare = name
        for suffix in [".savedState", ".binarycookies", ".plist"] where bare.hasSuffix(suffix) {
            bare = String(bare.dropLast(suffix.count))
            break
        }
        if folder == "Preferences/ByHost", let dot = bare.lastIndex(of: "."),
           Self.looksLikeHostIdentifier(String(bare[bare.index(after: dot)...])) {
            bare = String(bare[..<dot])
        }
        guard AppScanner.usableIdentifier(bare) != nil,
              AppLeftoverScanner.scope(of: bare) == .specific
        else { return nil }
        return bare
    }

    /// The hardware identifier `ByHost` appends: a UUID, or the older
    /// 12-character hexadecimal MAC address.
    private static func looksLikeHostIdentifier(_ text: String) -> Bool {
        if UUID(uuidString: text) != nil { return true }
        return text.count == 12 && text.allSatisfy(\.isHexDigit)
    }

    /// Whether an installed app's identifier covers this name.
    static func isClaimed(_ identifier: String, by installed: Set<String>) -> Bool {
        installed.contains { other in
            identifier == other || identifier.hasPrefix(other + ".") || other.hasPrefix(identifier + ".")
        }
    }

    /// What makes these files an app's, or `nil` when there is not enough to
    /// say so — a command-line tool's settings file on its own, for instance.
    static func evidence(for places: [Place]) -> [String]? {
        let strong = places.filter(\.strong)
        if !strong.isEmpty {
            return strong.map { "It left " + $0.what + ", which only an app does." }
        }
        let supporting = places.filter(\.supporting)
        if supporting.count >= 2 {
            return ["It left " + supporting.map(\.what).joined(separator: " and ") + "."]
        }
        return nil
    }
}
