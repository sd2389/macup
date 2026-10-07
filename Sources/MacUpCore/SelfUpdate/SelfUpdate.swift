import Foundation

/// A copy of MacUp on this Mac, and who is responsible for updating it.
public struct MacUpInstallation: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// `brew install sd2389/macup/macup` installed the command.
        case homebrewFormula
        /// A Homebrew cask installed the app.
        case homebrewCask
        /// Downloaded and moved into place by hand. Homebrew does not know
        /// about it, so MacUp cannot update it: only you can.
        case downloaded
    }

    public var kind: Kind
    /// The item an update would name, for the two Homebrew kinds.
    public var item: PackageID?
    /// Where this copy is: the `macup` command, or the app bundle.
    public var path: String?

    public init(kind: Kind, item: PackageID? = nil, path: String? = nil) {
        self.kind = kind
        self.item = item
        self.path = path
    }

    public var id: String { kind.rawValue + (path ?? "") }

    public var displayName: String {
        switch kind {
        case .homebrewFormula: "The macup command, installed by Homebrew"
        case .homebrewCask: "The MacUp app, installed by Homebrew"
        case .downloaded: "A copy you downloaded"
        }
    }
}

/// How MacUp updates itself, and what it can say about it.
///
/// MacUp opens no network connection of its own (CLAUDE.md §18), so it never
/// asks a server whether a new version exists. Instead it updates the way it
/// was installed: when Homebrew installed MacUp, Homebrew's own outdated data
/// — already read by every `macup check` — says whether there is a newer
/// version, and the update is an ordinary Homebrew update that goes through
/// the same plan, policy, execution, verification, and history as any other.
/// A copy that was downloaded by hand is told where its releases are and
/// nothing else: MacUp will not fetch, unpack, or replace itself.
public struct SelfUpdateStatus: Sendable, Hashable, Codable {
    public var runningVersion: String
    /// Every copy of MacUp this Mac has that MacUp could identify.
    public var installations: [MacUpInstallation]
    /// The updates Homebrew has for them. Empty when there are none.
    public var updates: [UpdateCandidate]
    /// Set when the Homebrew provider could not be used, so "no update" would
    /// be a guess rather than an answer.
    public var unknownReason: String?
    public var releasesURL: String

    public init(
        runningVersion: String,
        installations: [MacUpInstallation],
        updates: [UpdateCandidate],
        unknownReason: String? = nil,
        releasesURL: String = SelfUpdate.releasesURL
    ) {
        self.runningVersion = runningVersion
        self.installations = installations
        self.updates = updates
        self.unknownReason = unknownReason
        self.releasesURL = releasesURL
    }

    /// Whether Homebrew installed any copy, and so can update it.
    public var isManagedByHomebrew: Bool { installations.contains { $0.kind != .downloaded } }
    public var hasUpdate: Bool { !updates.isEmpty }

    /// One line for the top of a screen or a terminal.
    public var headline: String {
        if let reason = unknownReason {
            return "MacUp \(runningVersion). Whether a newer version exists is unknown: \(reason)"
        }
        if let update = updates.first {
            return "MacUp \(runningVersion) can be updated to \(update.availableVersion.raw)."
        }
        if isManagedByHomebrew {
            return "MacUp \(runningVersion) is up to date, according to Homebrew."
        }
        return "MacUp \(runningVersion) was not installed by a package manager, so MacUp cannot update it."
    }
}

public enum SelfUpdate {
    /// Where a downloaded copy gets its next version. MacUp never opens it
    /// itself: the CLI prints it, and the app hands it to the browser.
    public static let releasesURL = "https://github.com/sd2389/macup/releases"

    /// The formula and cask name MacUp is published under. A tapped formula
    /// is `sd2389/macup/macup`, so names are compared by their last part.
    public static let packageName = "macup"

    /// What this Mac has, from a check that has already run.
    ///
    /// Reads only what the check already gathered plus the file system: it
    /// runs no command of its own.
    public static func status(
        check: CheckReport,
        executablePath: String?,
        appBundlePath: String?,
        fileSystem: any FileSystem,
        runningVersion: String = MacUp.version
    ) -> SelfUpdateStatus {
        let homebrew = check.providers.first { $0.provider == .homebrew }
        let prefix = homebrew?.facts.first { $0.key == "prefix" }?.value
        var installations: [MacUpInstallation] = []

        if let prefix, let executablePath,
           isInside(executablePath, prefix + "/Cellar/" + packageName, fileSystem: fileSystem) {
            installations.append(MacUpInstallation(
                kind: .homebrewFormula,
                item: candidate(in: check, namespace: .brew)?.id ?? (try? PackageID(.brew, packageName)),
                path: executablePath
            ))
        }
        if let prefix, fileSystem.isDirectory(atPath: prefix + "/Caskroom/" + packageName) {
            installations.append(MacUpInstallation(
                kind: .homebrewCask,
                item: candidate(in: check, namespace: .brewCask)?.id ?? (try? PackageID(.brewCask, packageName)),
                path: appBundlePath
            ))
        }
        if installations.isEmpty {
            installations.append(MacUpInstallation(kind: .downloaded, path: appBundlePath ?? executablePath))
        }

        let kinds = Set(installations.map(\.kind))
        let updates = [(PackageNamespace.brew, MacUpInstallation.Kind.homebrewFormula), (.brewCask, .homebrewCask)]
            .filter { kinds.contains($0.1) }
            .compactMap { candidate(in: check, namespace: $0.0) }

        return SelfUpdateStatus(
            runningVersion: runningVersion,
            installations: installations,
            updates: updates,
            unknownReason: unknownReason(homebrew, installations: installations)
        )
    }

    /// Why "no update" would be a guess: Homebrew could not be used, so its
    /// outdated list is missing rather than empty (CLAUDE.md §2: ambiguity is
    /// reported, never smoothed over).
    private static func unknownReason(_ homebrew: ProviderReport?, installations: [MacUpInstallation]) -> String? {
        guard installations.contains(where: { $0.kind != .downloaded }) else { return nil }
        switch homebrew?.availability {
        case .available, nil: return nil
        case .disabled: return "Homebrew is turned off in MacUp's configuration."
        case .unavailable: return "MacUp did not find Homebrew, which installed this copy."
        case .failed: return homebrew?.errors.first?.error.message ?? "Homebrew could not be used."
        }
    }

    /// The update the check found for MacUp itself in this namespace, by the
    /// package's own name rather than the tap it came from.
    private static func candidate(in check: CheckReport, namespace: PackageNamespace) -> UpdateCandidate? {
        check.updates.first { candidate in
            candidate.id.namespace == namespace
                && (candidate.id.name.split(separator: "/").last.map(String.init) ?? candidate.id.name) == packageName
        }
    }

    private static func isInside(_ path: String, _ directory: String, fileSystem: any FileSystem) -> Bool {
        FileTree.isInside(
            fileSystem.canonicalPath(ofPath: path) ?? path,
            fileSystem.canonicalPath(ofPath: directory) ?? directory
        )
    }
}
