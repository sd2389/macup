import Darwin
import Foundation

/// Where an uninstall looks, and the parts of the Mac it asks about, all
/// injectable so a test can describe a Mac inside a temporary folder and
/// never touch the real one.
public struct UninstallEnvironment: Sendable {
    public var homeDirectory: String
    /// `/Applications` and `~/Applications`.
    public var applicationDirectories: [String]
    /// `/Library`, read for what only an administrator can remove.
    public var systemLibrary: String
    /// Installer-package receipts, `/private/var/db/receipts`.
    public var receiptsDirectory: String
    /// Where python.org installs Python, `/Library/Frameworks/Python.framework`.
    public var pythonFramework: String
    /// Where a copy of the `macup` command may have been installed.
    public var macUpCommandLocations: [String]
    /// The MacUp app that is asking, when the app is the one uninstalling
    /// MacUp. It is removed last, and is not "MacUp is still running".
    public var currentAppBundle: String?
    /// Where nothing is ever removed. ``RemovalBoundary/standardSystemPrefixes``
    /// on a real Mac; a test's temporary folder lives under one of those, so
    /// a test passes its own.
    public var systemPrefixes: [String]
    public var userID: uid_t
    public var runningApplications: any RunningApplicationChecking
    public var signatures: any CodeSignatureReading
    public var keychain: any MacUpKeychainItemStoring
    public var remover: GuardedFileRemover

    public init(
        homeDirectory: String,
        applicationDirectories: [String],
        systemLibrary: String,
        receiptsDirectory: String,
        pythonFramework: String,
        macUpCommandLocations: [String],
        currentAppBundle: String? = nil,
        systemPrefixes: [String] = RemovalBoundary.standardSystemPrefixes,
        userID: uid_t = getuid(),
        runningApplications: any RunningApplicationChecking,
        signatures: any CodeSignatureReading,
        keychain: any MacUpKeychainItemStoring,
        remover: GuardedFileRemover
    ) {
        self.homeDirectory = PathDisplay.standardized(homeDirectory)
        self.applicationDirectories = applicationDirectories
        self.systemLibrary = systemLibrary
        self.receiptsDirectory = receiptsDirectory
        self.pythonFramework = pythonFramework
        self.macUpCommandLocations = macUpCommandLocations
        self.currentAppBundle = currentAppBundle
        self.systemPrefixes = systemPrefixes
        self.userID = userID
        self.runningApplications = runningApplications
        self.signatures = signatures
        self.keychain = keychain
        self.remover = remover
    }

    /// This Mac.
    public static func live(homeDirectory: String, currentAppBundle: String? = nil) -> UninstallEnvironment {
        let home = PathDisplay.standardized(homeDirectory)
        return UninstallEnvironment(
            homeDirectory: home,
            applicationDirectories: ["/Applications", home + "/Applications"],
            systemLibrary: "/Library",
            receiptsDirectory: "/private/var/db/receipts",
            pythonFramework: "/Library/Frameworks/Python.framework",
            macUpCommandLocations: [home + "/.local/bin/macup", "/usr/local/bin/macup", "/opt/homebrew/bin/macup"],
            currentAppBundle: currentAppBundle,
            runningApplications: SystemRunningApplications(),
            signatures: SystemCodeSignatures(),
            keychain: SystemMacUpKeychainItems(),
            remover: GuardedFileRemover()
        )
    }

    /// The boundary one plan's removals are checked against.
    ///
    /// MacUp's own command is removable outside the home folder only when
    /// MacUp is what is being uninstalled; no other plan can reach it.
    public func boundary(homebrewPrefix: String?, forMacUp: Bool) -> RemovalBoundary {
        RemovalBoundary.standard(
            homeDirectory: homeDirectory,
            applicationDirectories: applicationDirectories,
            systemPrefixes: systemPrefixes,
            homebrewPrefix: homebrewPrefix,
            exactFiles: forMacUp ? Set(macUpCommandLocations) : []
        )
    }
}

/// A package one of the package managers says is installed, as something to
/// uninstall.
public struct UninstallablePackage: Sendable, Hashable, Codable, Identifiable {
    /// How to name it: `brew:mysql`, `brew-cask:firefox`, `npm:typescript`,
    /// `mise:node@22.1.0`.
    public var target: String
    public var packageID: PackageID
    public var kind: UninstallSubject.Kind
    public var name: String
    public var version: String?
    /// Something worth knowing at a glance, such as "in use" for a mise
    /// runtime or the other installed versions of a formula.
    public var note: String?
    /// The app a cask installed, when it installed one.
    public var appPath: String?

    public init(
        target: String,
        packageID: PackageID,
        kind: UninstallSubject.Kind,
        name: String,
        version: String?,
        note: String? = nil,
        appPath: String? = nil
    ) {
        self.target = target
        self.packageID = packageID
        self.kind = kind
        self.name = name
        self.version = version
        self.note = note
        self.appPath = appPath
    }

    public var id: String { target }
    public var provider: ProviderID { packageID.provider }
}

/// Something installed that MacUp can see but will not uninstall, such as a
/// python.org Python, with the steps to remove it by hand.
public struct ManualInstall: Sendable, Hashable, Codable, Identifiable {
    public var name: String
    public var path: String
    public var reason: String
    public var steps: [String]

    public init(name: String, path: String, reason: String, steps: [String]) {
        self.name = name
        self.path = path
        self.reason = reason
        self.steps = steps
    }

    public var id: String { path }
}

/// Whether a package manager could be asked what it has installed.
public struct UninstallProviderState: Sendable, Hashable, Codable {
    public enum State: String, Sendable, Hashable, Codable {
        case available
        /// Turned off in MacUp's configuration, so MacUp asked it nothing.
        case off
        case notInstalled
        case failed
    }

    public var provider: ProviderID
    public var state: State
    public var message: String?

    public init(provider: ProviderID, state: State, message: String? = nil) {
        self.provider = provider
        self.state = state
        self.message = message
    }
}

/// Everything on this Mac MacUp can uninstall, and what it can see but will
/// not: `macup uninstall --list` and the Uninstall screen. Read-only.
///
/// Schema version 1 (`"kind": "uninstallList"`).
public struct UninstallCatalog: Sendable, Hashable {
    public static let schemaVersion = 1

    public var createdAt: Date
    public var apps: [InstalledApp]
    public var packages: [UninstallablePackage]
    /// What apps that are no longer installed left in `~/Library`, biggest
    /// group first. Empty unless the scan was asked for them.
    public var orphans: [OrphanedLeftovers]
    public var manualInstalls: [ManualInstall]
    public var providers: [UninstallProviderState]
    /// Every command MacUp ran to make the list, redacted.
    public var commands: [CommandRecord]

    // What planning needs and the list does not show.
    var installations: [ProviderID: ProviderInstallation]
    var formulae: [ManagedItem]
    var casks: [HomebrewCask]
    var npmItems: [ManagedItem]
    var miseItems: [ManagedItem]

    public init(
        createdAt: Date,
        apps: [InstalledApp] = [],
        packages: [UninstallablePackage] = [],
        orphans: [OrphanedLeftovers] = [],
        manualInstalls: [ManualInstall] = [],
        providers: [UninstallProviderState] = [],
        commands: [CommandRecord] = []
    ) {
        self.createdAt = createdAt
        self.apps = apps
        self.packages = packages
        self.orphans = orphans
        self.manualInstalls = manualInstalls
        self.providers = providers
        self.commands = commands
        installations = [:]
        formulae = []
        casks = []
        npmItems = []
        miseItems = []
    }

    public func state(of provider: ProviderID) -> UninstallProviderState? {
        providers.first { $0.provider == provider }
    }

    public func packages(of provider: ProviderID) -> [UninstallablePackage] {
        packages.filter { $0.provider == provider }
    }
}

extension UninstallCatalog: Encodable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, macupVersion, createdAt, apps, packages, orphans, manualInstalls, providers, commands
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode("uninstallList", forKey: .kind)
        try container.encode(MacUp.version, forKey: .macupVersion)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(apps, forKey: .apps)
        try container.encode(packages, forKey: .packages)
        try container.encode(orphans, forKey: .orphans)
        try container.encode(manualInstalls, forKey: .manualInstalls)
        try container.encode(providers, forKey: .providers)
        try container.encode(commands, forKey: .commands)
    }
}
