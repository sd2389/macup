import Darwin
import Foundation

/// An app bundle in an Applications folder, as MacUp found it.
public struct InstalledApp: Sendable, Hashable, Codable, Identifiable {
    /// Where the app came from, which decides who removes it.
    public struct Source: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Hashable, Codable {
            /// Has a Mac App Store receipt.
            case appStore
            /// A Homebrew cask installed it, and `brew uninstall --cask`
            /// removes it.
            case homebrewCask
            /// Neither: most likely downloaded and dragged in.
            case downloaded
            /// Part of macOS.
            case system
        }

        public var kind: Kind
        /// The cask, for ``Kind/homebrewCask``.
        public var caskToken: String?

        public init(kind: Kind, caskToken: String? = nil) {
            self.kind = kind
            self.caskToken = caskToken
        }

        public var displayName: String {
            switch kind {
            case .appStore: "Mac App Store"
            case .homebrewCask: "Homebrew cask"
            case .downloaded: "Downloaded"
            case .system: "macOS"
            }
        }
    }

    /// Whether MacUp can remove the bundle, and why not.
    public struct Removability: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Hashable, Codable {
            case removable
            /// macOS protects it (System Integrity Protection, or the sealed
            /// system volume).
            case protectedBySystem
            /// Moving it needs an administrator's password.
            case needsAdministrator
            /// MacUp does not remove it for another reason, stated.
            case notSupported
        }

        public var kind: Kind
        public var reason: String?
        /// What to do by hand instead.
        public var steps: [String]

        public init(kind: Kind, reason: String? = nil, steps: [String] = []) {
            self.kind = kind
            self.reason = reason
            self.steps = steps
        }

        public static let removable = Removability(kind: .removable)
        public var isRemovable: Bool { kind == .removable }
    }

    public var path: String
    /// What Finder shows: the bundle's file name without `.app`.
    public var name: String
    public var bundleIdentifier: String?
    /// `CFBundleName` and `CFBundleDisplayName`, when the bundle has them.
    public var bundleNames: [String]
    public var version: String?
    public var sizeBytes: Int64?
    public var sizeIsPartial: Bool
    public var source: Source
    public var removability: Removability
    public var identity: FileIdentity?

    public init(
        path: String,
        name: String,
        bundleIdentifier: String?,
        bundleNames: [String] = [],
        version: String?,
        sizeBytes: Int64? = nil,
        sizeIsPartial: Bool = false,
        source: Source,
        removability: Removability,
        identity: FileIdentity? = nil
    ) {
        self.path = path
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundleNames = bundleNames
        self.version = version
        self.sizeBytes = sizeBytes
        self.sizeIsPartial = sizeIsPartial
        self.source = source
        self.removability = removability
        self.identity = identity
    }

    public var id: String { path }

    /// How to name it on the command line: `app:<bundle id>`, or its path
    /// when it has no bundle identifier MacUp could read.
    public var target: String {
        bundleIdentifier.map { "app:" + $0 } ?? path
    }

    /// Every name the app goes by, for matching folders named after it.
    public var names: [String] {
        var seen = Set<String>()
        return ([name] + bundleNames).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Finds the app bundles in the Applications folders: each folder's apps,
/// and the apps one folder down (`/Applications/Utilities/…`), never deeper.
///
/// Reading only. What is inside an app is read from its `Info.plist` and
/// `_MASReceipt`; whether MacUp may remove it is decided from what the file
/// system says — who owns it, whether its folder can be written, whether
/// macOS has locked it — never from its name.
public struct AppScanner: Sendable {
    public var applicationDirectories: [String]

    public init(applicationDirectories: [String]) {
        self.applicationDirectories = applicationDirectories
    }

    /// Every app, in folder order and then by name.
    ///
    /// - Parameters:
    ///   - caskApps: app paths a Homebrew cask installed, by canonical path.
    ///   - measure: add up each app's size, which reads every file in it.
    public func scan(caskApps: [String: String] = [:], measure: Bool) async -> [InstalledApp] {
        var paths: [String] = []
        for directory in applicationDirectories {
            for name in FileTree.names(in: directory) ?? [] where !name.hasPrefix(".") {
                let path = directory + "/" + name
                if name.hasSuffix(".app") {
                    paths.append(path)
                } else if FileTree.isDirectory(path) {
                    for inner in FileTree.names(in: path) ?? [] where inner.hasSuffix(".app") && !inner.hasPrefix(".") {
                        paths.append(path + "/" + inner)
                    }
                }
            }
        }
        // Measuring is the slow part, so apps are read a few at a time.
        return await withTaskGroup(of: (Int, InstalledApp?).self) { group in
            var results: [(Int, InstalledApp?)] = []
            var next = 0
            let width = 4
            func add(_ index: Int) {
                let path = paths[index]
                group.addTask { (index, self.app(at: path, caskApps: caskApps, measure: measure)) }
            }
            while next < min(width, paths.count) {
                add(next)
                next += 1
            }
            for await result in group {
                results.append(result)
                if next < paths.count {
                    add(next)
                    next += 1
                }
            }
            return results.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
    }

    /// One app, or `nil` when there is nothing at `path`.
    public func app(at path: String, caskApps: [String: String] = [:], measure: Bool) -> InstalledApp? {
        guard let status = FileTree.status(path) else { return nil }
        let fileName = (path as NSString).lastPathComponent
        let name = fileName.hasSuffix(".app") ? String(fileName.dropLast(4)) : fileName

        if status.kind == .symlink {
            return link(at: path, name: name, status: status)
        }
        guard status.kind == .directory else { return nil }

        let info = FileTree.propertyList(path + "/Contents/Info.plist")
        let identifier = (info?["CFBundleIdentifier"] as? String).flatMap(Self.usableIdentifier)
        let names = ["CFBundleName", "CFBundleDisplayName"].compactMap { info?[$0] as? String }.filter(Self.isShowable)
        let version = ((info?["CFBundleShortVersionString"] as? String) ?? (info?["CFBundleVersion"] as? String))
            .flatMap { Self.isShowable($0) ? $0 : nil }

        let canonical = FileTree.canonicalPath(path) ?? path
        var source = InstalledApp.Source(kind: .downloaded)
        if let token = caskApps[canonical] {
            source = InstalledApp.Source(kind: .homebrewCask, caskToken: token)
        } else if FileTree.exists(path + "/Contents/_MASReceipt/receipt") {
            source = InstalledApp.Source(kind: .appStore)
        }

        let size = measure ? FileTree.size(of: path) : nil
        return InstalledApp(
            path: path,
            name: name,
            bundleIdentifier: identifier,
            bundleNames: names,
            version: version,
            sizeBytes: size?.bytes,
            sizeIsPartial: (size?.partial ?? false) || (size?.unreadable ?? 0) > 0,
            source: source,
            removability: removability(of: path, canonical: canonical, status: status, source: source, size: size, name: name),
            identity: status.identity
        )
    }

    /// An `.app` that is a link. Safari is one: macOS keeps it on the sealed
    /// system volume and leaves a protected link in /Applications.
    private func link(at path: String, name: String, status: FileTree.Status) -> InstalledApp {
        let target = FileTree.canonicalPath(path)
        let info = target.flatMap { FileTree.propertyList($0 + "/Contents/Info.plist") }
        let identifier = (info?["CFBundleIdentifier"] as? String).flatMap(Self.usableIdentifier)
        let version = (info?["CFBundleShortVersionString"] as? String).flatMap { Self.isShowable($0) ? $0 : nil }
        let system = status.isLocked || target.map { FileTree.isWithin($0, "/System") } == true
        let removability = system
            ? InstalledApp.Removability(kind: .protectedBySystem, reason: "macOS protects \(name) as part of the system, so it cannot be removed.")
            : InstalledApp.Removability(
                kind: .notSupported,
                reason: "This is a link to \(target ?? "an app that is not there"), so MacUp leaves it alone.",
                steps: ["Remove the link in Finder if you no longer want it, or uninstall the app it points to."]
            )
        return InstalledApp(
            path: path,
            name: name,
            bundleIdentifier: identifier,
            version: version,
            source: InstalledApp.Source(kind: system ? .system : .downloaded),
            removability: removability,
            identity: status.identity
        )
    }

    private func removability(
        of path: String,
        canonical: String,
        status: FileTree.Status,
        source: InstalledApp.Source,
        size: FileTree.SizeReading?,
        name: String
    ) -> InstalledApp.Removability {
        if FileTree.isWithin(canonical, "/System") || status.isLocked || FileTree.isOnReadOnlyVolume(path) {
            return InstalledApp.Removability(
                kind: .protectedBySystem,
                reason: "macOS protects \(name), so it cannot be removed."
            )
        }
        let finder = "In Finder, drag \(name) from Applications to the Trash, and enter an administrator's password when macOS asks."
        let steps = source.kind == .appStore
            ? ["Open Launchpad, hold down the Option key, and click the delete button on \(name).", finder]
            : [finder]
        let parent = (path as NSString).deletingLastPathComponent
        if !FileTree.isWritable(parent) || !FileTree.isWritable(path) {
            let who = Self.ownerPhrase(owner: status.owner, user: getuid())
            return InstalledApp.Removability(
                kind: .needsAdministrator,
                reason: "Removing \(name) needs an administrator: \(who)"
                    + (source.kind == .appStore ? ", as the App Store installs it." : "."),
                steps: steps
            )
        }
        if let size, size.locked > 0 {
            return InstalledApp.Removability(
                kind: .needsAdministrator,
                reason: "Some files inside \(name) belong to another user or are locked, so removing it needs an administrator.",
                steps: steps
            )
        }
        return .removable
    }

    /// Why the app cannot be moved without an administrator, from who owns
    /// it. An installer package puts an app in `/Applications` as root, which
    /// is the common case and not another person's account, so it is not
    /// described as one.
    static func ownerPhrase(owner: uid_t, user: uid_t) -> String {
        switch owner {
        case user: "you do not have permission to move it"
        case 0: "an installer put it there as root"
        default: "it belongs to another user"
        }
    }

    /// A bundle identifier MacUp is willing to use to name folders:
    /// reverse-DNS characters only, no path separators, no leading dot.
    static func usableIdentifier(_ value: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard !value.isEmpty, value.count <= 255, !value.hasPrefix("."), !value.hasSuffix("."),
              !value.contains(".."), value.unicodeScalars.allSatisfy(allowed.contains)
        else { return nil }
        return value
    }

    static func isShowable(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 255 && !value.contains("/") && !value.unicodeScalars.contains(where: TerminalText.isUnsafe)
    }
}
