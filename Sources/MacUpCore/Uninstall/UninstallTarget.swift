import Foundation

/// What someone asked to uninstall, resolved against what is installed.
public enum UninstallTarget: Sendable, Hashable {
    case app(InstalledApp)
    case package(UninstallablePackage)
    /// What an app that is no longer installed left in `~/Library`.
    case leftovers(OrphanedLeftovers)
    /// MacUp itself: `macup self-uninstall`, or Uninstall MacUp in Settings.
    case macUp
}

/// Why a name did not resolve to exactly one thing.
public struct UninstallTargetError: Error, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case notFound
        case ambiguous
        case invalid
    }

    public var kind: Kind
    public var message: String
    /// What the name could have meant, for an ambiguous one.
    public var candidates: [String]

    public init(_ kind: Kind, _ message: String, candidates: [String] = []) {
        self.kind = kind
        self.message = message
        self.candidates = candidates
    }
}

/// Turns what was typed into one installed thing, or says why it cannot.
///
/// Four forms, and nothing looser: a package ID (`brew:mysql`,
/// `brew-cask:firefox`, `npm:typescript`, `mise:node@22`), an app by bundle
/// identifier (`app:com.openai.chat`), an app's path, or an app's name as
/// Finder shows it. `app:` exists only here, in the uninstaller: it is not a
/// package namespace, so policies and updates never see it.
///
/// A name that could mean two things is refused with both, never settled by
/// picking one. A mise runtime needs a version unless only one is installed,
/// and a version prefix (`node@22`) must match exactly one installed version.
public enum UninstallTargetResolver {
    public static func resolve(_ text: String, in catalog: UninstallCatalog, homeDirectory: String) -> Result<UninstallTarget, UninstallTargetError> {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, !typed.unicodeScalars.contains(where: TerminalText.isUnsafe) else {
            return .failure(UninstallTargetError(.invalid, "That is not something MacUp can look for."))
        }
        if typed.lowercased() == "macup" || typed == "app:" + MacUpSelf.bundleIdentifier {
            return .success(.macUp)
        }
        if typed.hasPrefix(OrphanScanner.targetPrefix) {
            return leftovers(identifier: String(typed.dropFirst(OrphanScanner.targetPrefix.count)), in: catalog)
        }
        if typed.hasPrefix("app:") {
            return app(identifier: String(typed.dropFirst(4)), in: catalog)
        }
        if typed.hasPrefix("/") || typed.hasPrefix("~") || typed.hasSuffix(".app") && typed.contains("/") {
            return app(path: typed, in: catalog, homeDirectory: homeDirectory)
        }
        if let separator = typed.firstIndex(of: ":"),
           PackageNamespace.known.contains(PackageNamespace(rawValue: String(typed[..<separator]))) {
            return package(typed, in: catalog)
        }
        return app(name: typed, in: catalog)
    }

    /// `leftovers:com.example.app`, which names a group the scan found. It
    /// resolves only against a scan that looked for them, so a group nobody
    /// has seen cannot be removed by typing its name.
    private static func leftovers(identifier: String, in catalog: UninstallCatalog) -> Result<UninstallTarget, UninstallTargetError> {
        guard let group = catalog.orphans.first(where: { $0.identifier == identifier }) else {
            return .failure(UninstallTargetError(
                .notFound,
                "MacUp found no leftovers named after \(TerminalText.sanitize(identifier)). "
                    + "`macup uninstall --orphans` lists what it did find."
            ))
        }
        return .success(.leftovers(group))
    }

    private static func app(identifier: String, in catalog: UninstallCatalog) -> Result<UninstallTarget, UninstallTargetError> {
        let matches = catalog.apps.filter { $0.bundleIdentifier == identifier }
        return single(matches, typed: "app:" + identifier, noun: "an app with the bundle identifier \(identifier)")
    }

    private static func app(path: String, in catalog: UninstallCatalog, homeDirectory: String) -> Result<UninstallTarget, UninstallTargetError> {
        var expanded = path == "~" ? homeDirectory : path.hasPrefix("~/") ? homeDirectory + path.dropFirst() : path
        expanded = (expanded as NSString).standardizingPath
        let canonical = FileTree.canonicalPath(expanded)
        let matches = catalog.apps.filter { app in
            app.path == expanded || (canonical != nil && FileTree.canonicalPath(app.path) == canonical)
        }
        if matches.isEmpty {
            return .failure(UninstallTargetError(
                .notFound,
                "MacUp found no app at \(PathDisplay.abbreviatingHome(expanded, homeDirectory: homeDirectory)). It uninstalls apps in /Applications and ~/Applications, and one folder down."
            ))
        }
        return single(matches, typed: path, noun: "an app at that path")
    }

    private static func app(name: String, in catalog: UninstallCatalog) -> Result<UninstallTarget, UninstallTargetError> {
        let bare = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        let matches = catalog.apps.filter { app in
            app.names.contains { $0.caseInsensitiveCompare(bare) == .orderedSame }
        }
        if matches.isEmpty {
            let packages = catalog.packages.filter { $0.name.caseInsensitiveCompare(bare) == .orderedSame }
            let hint = packages.isEmpty ? "" : " Did you mean " + packages.map(\.target).joined(separator: " or ") + "?"
            return .failure(UninstallTargetError(
                .notFound,
                "No app called \(name) is in /Applications or ~/Applications.\(hint)",
                candidates: packages.map(\.target)
            ))
        }
        if matches.count > 1 {
            return .failure(UninstallTargetError(
                .ambiguous,
                "More than one app is called \(name). Name the one you mean by its path.",
                candidates: matches.map(\.path)
            ))
        }
        return single(matches, typed: name, noun: "an app called \(name)")
    }

    private static func single(_ matches: [InstalledApp], typed: String, noun: String) -> Result<UninstallTarget, UninstallTargetError> {
        switch matches.count {
        case 0:
            return .failure(UninstallTargetError(.notFound, "MacUp found no \(noun) in /Applications or ~/Applications."))
        case 1:
            if matches[0].bundleIdentifier == MacUpSelf.bundleIdentifier { return .success(.macUp) }
            return .success(.app(matches[0]))
        default:
            return .failure(UninstallTargetError(
                .ambiguous,
                "More than one copy of \(typed) is installed. Name the one you mean by its path.",
                candidates: matches.map(\.path)
            ))
        }
    }

    private static func package(_ typed: String, in catalog: UninstallCatalog) -> Result<UninstallTarget, UninstallTargetError> {
        let id: PackageID
        do {
            id = try PackageID(parsing: typed)
        } catch let error as PackageID.ValidationError {
            return .failure(UninstallTargetError(.invalid, error.description))
        } catch {
            return .failure(UninstallTargetError(.invalid, "\(typed) is not a package ID."))
        }
        switch id.namespace {
        case .macos:
            return .failure(UninstallTargetError(.invalid, "MacUp does not uninstall macOS updates."))
        case .mise:
            return mise(id, in: catalog)
        default:
            break
        }
        if let exact = catalog.packages.first(where: { $0.packageID == id && $0.kind != .miseRuntime }) {
            return .success(.package(exact))
        }
        // A tap's formula is listed by its full name; its short name is
        // accepted when it names only one.
        if id.namespace == .brew {
            let short = catalog.packages.filter { $0.kind == .formula && $0.packageID.name.split(separator: "/").last.map(String.init) == id.name }
            if short.count == 1 { return .success(.package(short[0])) }
            if short.count > 1 {
                return .failure(UninstallTargetError(.ambiguous, "More than one tap has a formula called \(id.name).", candidates: short.map(\.target)))
            }
        }
        let provider = id.provider.displayName
        let state = catalog.state(of: id.provider)
        if let state, state.state != .available {
            return .failure(UninstallTargetError(.notFound, state.message ?? "\(provider) could not be asked what is installed."))
        }
        return .failure(UninstallTargetError(.notFound, "\(provider) does not list \(typed) as installed."))
    }

    private static func mise(_ id: PackageID, in catalog: UninstallCatalog) -> Result<UninstallTarget, UninstallTargetError> {
        let runtimes = catalog.packages.filter { $0.kind == .miseRuntime }
        if let exact = runtimes.first(where: { $0.target == id.rawValue }) {
            return .success(.package(exact))
        }
        // `mise:node` or `mise:node@22`: the tool is everything up to the
        // last `@` that leaves a known tool, so `npm:@scope/name` works.
        var tool = id.name
        var prefix: String?
        if let at = id.name.lastIndex(of: "@"), at != id.name.startIndex {
            let candidate = String(id.name[..<at])
            if runtimes.contains(where: { $0.packageID.name == candidate }) {
                tool = candidate
                prefix = String(id.name[id.name.index(after: at)...])
            }
        }
        let versions = runtimes.filter { $0.packageID.name == tool }
        guard !versions.isEmpty else {
            if let state = catalog.state(of: .mise), state.state != .available {
                return .failure(UninstallTargetError(.notFound, state.message ?? "mise could not be asked what is installed."))
            }
            return .failure(UninstallTargetError(.notFound, "mise does not list \(id.rawValue) as installed."))
        }
        let matches = prefix.map { prefix in
            versions.filter { $0.version == prefix || ($0.version ?? "").hasPrefix(prefix + ".") }
        } ?? versions
        switch matches.count {
        case 1:
            return .success(.package(matches[0]))
        case 0:
            return .failure(UninstallTargetError(
                .notFound,
                "mise has no \(tool) \(prefix ?? "") installed.",
                candidates: versions.map(\.target)
            ))
        default:
            return .failure(UninstallTargetError(
                .ambiguous,
                "mise has more than one \(tool) installed. Name the version: " + matches.map(\.target).joined(separator: ", ") + ".",
                candidates: matches.map(\.target)
            ))
        }
    }
}

/// Facts about MacUp that uninstalling it needs.
public enum MacUpSelf {
    public static let bundleIdentifier = "dev.macup.MacUp"
}
