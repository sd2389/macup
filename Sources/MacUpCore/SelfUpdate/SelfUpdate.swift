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

    /// The copy that is running, which is always the first one listed.
    /// Another copy's provenance never answers for it.
    public var runningCopy: MacUpInstallation? { installations.first }
    /// Whether Homebrew installed **the copy that is running**, and so can
    /// update it. Another copy Homebrew manages does not make this true: what
    /// matters to the person asking is the MacUp they are using.
    public var isRunningCopyManagedByHomebrew: Bool { (runningCopy?.kind ?? .downloaded) != .downloaded }
    public var hasUpdate: Bool { !updates.isEmpty }

    /// One line for the top of a screen or a terminal.
    public var headline: String {
        if let reason = unknownReason {
            return "MacUp \(runningVersion). Whether a newer version exists is unknown: \(reason)"
        }
        if let update = updates.first {
            return "MacUp \(runningVersion) can be updated to \(update.availableVersion.raw)."
        }
        if isRunningCopyManagedByHomebrew {
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

        // The copy that is running, decided first and listed first. The
        // command Homebrew's formula installed lives inside the Cellar, which
        // is Homebrew's own folder, so containment is the evidence.
        var running: MacUpInstallation?
        if let prefix, let executablePath,
           isInside(executablePath, prefix + "/Cellar/" + packageName, fileSystem: fileSystem) {
            running = MacUpInstallation(
                kind: .homebrewFormula,
                item: candidate(in: check, namespace: .brew)?.id ?? (try? PackageID(.brew, packageName)),
                path: executablePath
            )
        }

        // A cask is Homebrew's to report. A folder in the Caskroom is not
        // evidence: anyone who can write there can create one, and an empty
        // one would otherwise make a copy Homebrew never installed read as
        // Homebrew-managed and up to date.
        var other: MacUpInstallation?
        if let cask = installedCask(in: check) {
            // A cask does not keep its app in the Caskroom, so the running
            // copy is tied to it by living where a cask puts an app. A copy
            // anywhere else is somebody's download, whatever the cask holds.
            if running == nil, let appBundlePath, isInAppDirectory(appBundlePath) {
                running = MacUpInstallation(kind: .homebrewCask, item: cask, path: appBundlePath)
            } else {
                other = MacUpInstallation(kind: .homebrewCask, item: cask)
            }
        }

        // Always recorded, so the copy that is running can never be displaced
        // by another copy's provenance.
        var installations = [running ?? MacUpInstallation(kind: .downloaded, path: appBundlePath ?? executablePath)]
        if let other { installations.append(other) }

        // An update is offered for the copy that is running and no other: a
        // newer version of a copy sitting elsewhere on the Mac would not make
        // this MacUp any newer. Another copy's update is an ordinary item,
        // and `macup update brew-cask:macup` still runs it.
        let namespace: PackageNamespace? = switch installations[0].kind {
        case .homebrewFormula: .brew
        case .homebrewCask: .brewCask
        case .downloaded: nil
        }
        let updates = [namespace].compactMap { $0 }.compactMap { candidate(in: check, namespace: $0) }

        // Homebrew is the only thing that can say a cask installed this app,
        // so when it could not be asked, a copy sitting where a cask puts one
        // is undecided rather than downloaded.
        let mightBeACask = prefix != nil && appBundlePath.map(isInAppDirectory) == true

        return SelfUpdateStatus(
            runningVersion: runningVersion,
            installations: installations,
            updates: updates,
            unknownReason: unknownReason(homebrew, installations: installations, mightBeACask: mightBeACask)
        )
    }

    /// Why "no update" would be a guess: Homebrew could not be used, so its
    /// outdated list is missing rather than empty, and its installed-cask
    /// list with it (CLAUDE.md §2: ambiguity is reported, never smoothed
    /// over). Said for a copy Homebrew manages, and for one MacUp cannot
    /// place because Homebrew is the only thing that could have told it.
    private static func unknownReason(
        _ homebrew: ProviderReport?,
        installations: [MacUpInstallation],
        mightBeACask: Bool
    ) -> String? {
        guard installations.first?.kind != .downloaded || mightBeACask else { return nil }
        switch homebrew?.availability {
        case .available, nil: return nil
        case .disabled: return "Homebrew is turned off in MacUp's configuration."
        case .unavailable: return "MacUp did not find Homebrew, which is the only thing that could say how this copy was installed."
        case .failed: return homebrew?.errors.first?.error.message ?? "Homebrew could not be used."
        }
    }

    /// The MacUp cask Homebrew itself reports: one it listed as installed,
    /// or one it has an update for. Both come from Homebrew's own output,
    /// already read by the check that ran.
    private static func installedCask(in check: CheckReport) -> PackageID? {
        if let candidate = candidate(in: check, namespace: .brewCask) { return candidate.id }
        let installed = (check.providers.first { $0.provider == .homebrew }?.items ?? [])
            .first { item in
                item.id.namespace == .brewCask && lastName(item.id.name) == packageName
            }
        return installed?.id
    }

    /// Where a Homebrew cask puts an app: `/Applications` by default, or
    /// another folder of that name when `appdir` was changed. A bundle
    /// anywhere else is not the one a cask installed.
    private static func isInAppDirectory(_ appBundlePath: String) -> Bool {
        let parent = (appBundlePath as NSString).deletingLastPathComponent
        return (parent as NSString).lastPathComponent == "Applications"
    }

    private static func lastName(_ name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    /// The update the check found for MacUp itself in this namespace, by the
    /// package's own name rather than the tap it came from.
    private static func candidate(in check: CheckReport, namespace: PackageNamespace) -> UpdateCandidate? {
        check.updates.first { candidate in
            candidate.id.namespace == namespace
                && lastName(candidate.id.name) == packageName
        }
    }

    private static func isInside(_ path: String, _ directory: String, fileSystem: any FileSystem) -> Bool {
        FileTree.isInside(
            fileSystem.canonicalPath(ofPath: path) ?? path,
            fileSystem.canonicalPath(ofPath: directory) ?? directory
        )
    }
}
