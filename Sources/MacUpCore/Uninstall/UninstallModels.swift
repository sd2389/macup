import Foundation

/// How MacUp removes the files an uninstall removes itself.
///
/// It is chosen for each uninstall and never remembered. There is no setting
/// that could make a permanent deletion happen without the person choosing it
/// at the time (docs/TRUST_AND_SECURITY.md, "Uninstall").
public enum RemovalMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// `FileManager.trashItem`: everything can be put back from the Trash
    /// until the Trash is emptied.
    case trash
    /// `FileManager.removeItem`: gone, with no way back.
    case delete

    public var displayName: String {
        switch self {
        case .trash: "Move to Trash"
        case .delete: "Delete Permanently"
        }
    }

    /// What happened to an item, to end a sentence: "moved to the Trash".
    public var pastTense: String {
        switch self {
        case .trash: "moved to the Trash"
        case .delete: "deleted permanently"
        }
    }
}

/// What kind of thing is at a path, as `lstat` reports it: a symbolic link is
/// always a link, never what it points at.
public enum FileKind: String, Sendable, Hashable, Codable {
    case file
    case directory
    case symlink
    case other
}

/// Which file a path named when MacUp looked at it.
///
/// Recorded when a plan is made and compared again immediately before the
/// file is removed, so a path that now names something else — replaced,
/// swapped for a link, recreated — is skipped rather than removed.
public struct FileIdentity: Sendable, Hashable, Codable {
    public var device: Int64
    public var inode: UInt64
    public var kind: FileKind

    public init(device: Int64, inode: UInt64, kind: FileKind) {
        self.device = device
        self.inode = inode
        self.kind = kind
    }
}

/// Why a leftover is in a plan, which decides whether it is ticked.
///
/// Every category is found by a fixed rule — a name equal to the bundle ID, a
/// launch agent whose label or program points into the app, a path the
/// package manager itself lists — never by resemblance. The categories that
/// hold what a person made are left unticked.
public enum LeftoverCategory: String, Sendable, Hashable, Codable, CaseIterable {
    /// The app bundle itself, when no package manager owns it.
    case application
    /// Caches, preferences, saved window state, cookies, logs, and launch
    /// agents named after the bundle ID. Ticked.
    case belongsToApp
    /// Application Support, the sandbox container, and the developer's group
    /// container. Not ticked: this is what the app saved for you.
    case appData
    /// Folders named exactly like the app. Not ticked, because a name is only
    /// a name.
    case matchedByName
    /// Paths the package manager lists for a complete removal (a cask's
    /// `zap`). Ticked for caches and preferences, not for data.
    case declaredByPackageManager
    /// A formula's own data and settings folders, such as `var/mysql`. Not
    /// ticked.
    case formulaData
    /// Downloads the package manager keeps so it can reinstall without the
    /// network. Ticked.
    case downloadCache
    /// MacUp's own files, when MacUp is what is being uninstalled.
    case macUp

    public var title: String {
        switch self {
        case .application: "The app"
        case .belongsToApp: "Belongs to the app"
        case .appData: "App data"
        case .matchedByName: "Matched by name"
        case .declaredByPackageManager: "Listed by Homebrew"
        case .formulaData: "Data and settings"
        case .downloadCache: "Download caches"
        case .macUp: "MacUp's own files"
        }
    }

    /// What the reader should know about the whole group, when there is
    /// something worth saying.
    public var note: String? {
        switch self {
        case .appData:
            "Your chats, saved games, and settings in this app. Left in place unless you tick them."
        case .matchedByName:
            "Matched by name only; check before removing. Left in place unless you tick them."
        case .formulaData:
            "Databases, settings, and other data this package keeps. Left in place unless you tick them."
        case .declaredByPackageManager:
            "Homebrew lists these for a complete removal. MacUp removes each one itself, so your choices here apply."
        case .downloadCache:
            "Homebrew can download these again if you reinstall."
        case .application, .belongsToApp, .macUp:
            nil
        }
    }

    /// Whether this group holds what a person made or chose, which is why it
    /// is never ticked for them.
    public var isData: Bool {
        self == .appData || self == .formulaData
    }
}

/// One path an uninstall would remove, and everything the reader needs to
/// decide about it.
public struct PlannedRemoval: Sendable, Hashable, Codable, Identifiable {
    /// Where the item sits in the order MacUp removes things.
    public enum Role: String, Sendable, Hashable, Codable {
        /// An ordinary leftover.
        case item
        /// The app bundle being uninstalled. For an app it is removed first,
        /// and nothing else is touched if that fails; MacUp's own bundle is
        /// removed last.
        case bundle
        /// MacUp's state folder, where history lives. Removed after the
        /// uninstall is recorded, so the record is made while there is
        /// somewhere to keep it.
        case macUpState
    }

    /// Absolute and standardized; the identity of the item in a selection.
    public var path: String
    public var category: LeftoverCategory
    public var kind: FileKind
    /// Size on disk, as `du` counts it. `nil` when MacUp could not measure it.
    public var sizeBytes: Int64?
    /// The folder was too large to measure completely, so the size is a
    /// lower bound.
    public var sizeIsPartial: Bool
    public var selectedByDefault: Bool
    /// Removed whenever the uninstall runs: the bundle of an app that no
    /// package manager owns. Nothing else is ever required.
    public var isRequired: Bool
    public var role: Role
    /// Why MacUp thinks this belongs to what is being uninstalled.
    public var reason: String
    /// What removing it would cost, for data.
    public var warning: String?
    public var identity: FileIdentity?

    public init(
        path: String,
        category: LeftoverCategory,
        kind: FileKind,
        sizeBytes: Int64? = nil,
        sizeIsPartial: Bool = false,
        selectedByDefault: Bool,
        isRequired: Bool = false,
        role: Role = .item,
        reason: String,
        warning: String? = nil,
        identity: FileIdentity? = nil
    ) {
        self.path = path
        self.category = category
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.sizeIsPartial = sizeIsPartial
        self.selectedByDefault = selectedByDefault
        self.isRequired = isRequired
        self.role = role
        self.reason = reason
        self.warning = warning
        self.identity = identity
    }

    public var id: String { path }
}

/// Something that belongs to what is being uninstalled but that MacUp will not
/// remove, with what to do about it by hand.
public struct ManualRemoval: Sendable, Hashable, Codable, Identifiable {
    public var path: String
    public var reason: String
    /// The exact steps, in order. Commands are shell-quoted for copying and
    /// are never run by MacUp.
    public var steps: [String]
    public var sizeBytes: Int64?

    public init(path: String, reason: String, steps: [String], sizeBytes: Int64? = nil) {
        self.path = path
        self.reason = reason
        self.steps = steps
        self.sizeBytes = sizeBytes
    }

    public var id: String { path }
}

/// A reason an uninstall cannot run at all. A plan with a blocker is still
/// shown in full; it just cannot be carried out until the reason is gone.
public struct UninstallBlocker: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// The app is open. Checked again immediately before anything runs.
        case appRunning
        /// Other installed software needs it.
        case hasDependents
        /// The package manager holds it at its version.
        case pinned
        /// Removing it needs an administrator, which MacUp never is.
        case needsAdministrator
        /// macOS protects it.
        case protectedBySystem
        /// Its package manager is turned off in MacUp's configuration.
        case providerOff
        /// Its package manager could not be found or run.
        case providerUnavailable
        /// MacUp could not tell who manages it.
        case ownershipUnknown
        /// MacUp could not find it installed.
        case notInstalled
        /// MacUp does not uninstall this kind of thing.
        case unsupported
        /// MacUp's configuration could not be read, so MacUp changes nothing.
        case configurationInvalid
    }

    public var kind: Kind
    /// One display-safe sentence, such as "Quit ChatGPT first."
    public var message: String
    /// What to do instead, when there is something to do.
    public var steps: [String]
    /// What depends on the item, for ``Kind/hasDependents``.
    public var dependents: [PackageID]?

    public init(_ kind: Kind, _ message: String, steps: [String] = [], dependents: [PackageID]? = nil) {
        self.kind = kind
        self.message = message
        self.steps = steps
        self.dependents = dependents
    }
}

/// What an uninstall is about.
public struct UninstallSubject: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case app
        case formula
        case cask
        case npmPackage
        case miseRuntime
        case macUp

        public var displayName: String {
            switch self {
            case .app: "App"
            case .formula: "Homebrew formula"
            case .cask: "Homebrew cask"
            case .npmPackage: "npm global package"
            case .miseRuntime: "mise runtime"
            case .macUp: "MacUp"
            }
        }
    }

    public var kind: Kind
    /// How to name it on the command line: `app:com.openai.chat`,
    /// `brew:mysql`, `mise:node@22.1.0`, or `macup`.
    public var target: String
    /// The package, when a package manager owns it. `mise:node` for a mise
    /// runtime, whose version is ``version``.
    public var packageID: PackageID?
    public var name: String
    public var version: String?
    public var bundleIdentifier: String?
    public var bundlePath: String?
    /// Where it came from, in words: "Mac App Store", "Homebrew cask".
    public var source: String

    public init(
        kind: Kind,
        target: String,
        packageID: PackageID? = nil,
        name: String,
        version: String? = nil,
        bundleIdentifier: String? = nil,
        bundlePath: String? = nil,
        source: String
    ) {
        self.kind = kind
        self.target = target
        self.packageID = packageID
        self.name = name
        self.version = version
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.source = source
    }

    public var provider: ProviderID? { packageID?.provider }
}

/// Something MacUp does while uninstalling itself that is neither a package
/// manager's command nor a file: turning off its scheduled check, and deleting
/// a Keychain item an earlier version saved.
public struct SelfUninstallAction: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// `macup schedule disable`: unloads the launch agent and deletes it.
        case removeScheduledCheck
        /// Deletes MacUp's generic-password item from the login keychain.
        case deleteKeychainItem
    }

    public var kind: Kind
    public var summary: String
    /// The exact command or item, for display.
    public var detail: String?

    public init(kind: Kind, summary: String, detail: String? = nil) {
        self.kind = kind
        self.summary = summary
        self.detail = detail
    }

    public var id: String { kind.rawValue }
}

/// How many things a selection removes, and how much space.
public struct UninstallTotals: Sendable, Hashable, Codable {
    public var count: Int
    public var bytes: Int64
    /// Some sizes are lower bounds or unknown, so ``bytes`` is too.
    public var bytesArePartial: Bool
    public var keptCount: Int
    public var keptBytes: Int64

    public init(count: Int, bytes: Int64, bytesArePartial: Bool, keptCount: Int, keptBytes: Int64) {
        self.count = count
        self.bytes = bytes
        self.bytesArePartial = bytesArePartial
        self.keptCount = keptCount
        self.keptBytes = keptBytes
    }
}

/// Everything MacUp would do to uninstall one thing, shown before anything
/// runs: the package manager's exact commands, every file with its size and
/// why it is there, what MacUp will not remove and how to remove it by hand,
/// and how MacUp will confirm it worked.
///
/// A plan launches nothing. Schema version 1.
public struct UninstallPlan: Sendable, Hashable, Codable, Identifiable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var kind: String
    public var macupVersion: String
    public var id: UUID
    public var createdAt: Date
    public var subject: UninstallSubject
    public var rationale: String
    /// The package manager's commands, exact executable and arguments, in
    /// the order they run. Each is modifying.
    public var steps: [ExecutionStep]
    /// MacUp's own steps when it is uninstalling itself.
    public var actions: [SelfUninstallAction]
    /// In the order MacUp would remove them.
    public var removals: [PlannedRemoval]
    public var cannotRemove: [ManualRemoval]
    public var warnings: [String]
    public var blockers: [UninstallBlocker]
    /// How MacUp confirms it afterwards. Read-only.
    public var verification: [VerificationStep]
    /// About how much the package manager's own commands remove, when MacUp
    /// could measure it.
    public var packageManagerRemovesBytes: Int64?
    /// The Homebrew installation's prefix, whose `var` and `etc` hold the
    /// formula data a plan may offer.
    public var homebrewPrefix: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        subject: UninstallSubject,
        rationale: String,
        steps: [ExecutionStep] = [],
        actions: [SelfUninstallAction] = [],
        removals: [PlannedRemoval] = [],
        cannotRemove: [ManualRemoval] = [],
        warnings: [String] = [],
        blockers: [UninstallBlocker] = [],
        verification: [VerificationStep] = [],
        packageManagerRemovesBytes: Int64? = nil,
        homebrewPrefix: String? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.kind = "uninstallPlan"
        self.macupVersion = MacUp.version
        self.id = id
        self.createdAt = createdAt
        self.subject = subject
        self.rationale = rationale
        self.steps = steps
        self.actions = actions
        self.removals = removals
        self.cannotRemove = cannotRemove
        self.warnings = warnings
        self.blockers = blockers
        self.verification = verification
        self.packageManagerRemovesBytes = packageManagerRemovesBytes
        self.homebrewPrefix = homebrewPrefix
    }

    /// Whether anything stands in the way. Blockers that can change — an app
    /// that is open — are checked again immediately before anything runs.
    public var canRun: Bool { blockers.isEmpty }

    /// What is ticked when the plan is first shown.
    public var defaultSelection: Set<String> {
        Set(removals.filter { $0.selectedByDefault || $0.isRequired }.map(\.path))
    }

    /// Every path in the plan, for "Select everything".
    public var everything: Set<String> {
        Set(removals.map(\.path))
    }

    /// The removals a selection covers, in the plan's order. Required ones
    /// are always included, and a path the plan does not list never is.
    public func selectedRemovals(_ selection: Set<String>) -> [PlannedRemoval] {
        removals.filter { $0.isRequired || selection.contains($0.path) }
    }

    /// What a selection removes and what it leaves.
    public func totals(for selection: Set<String>) -> UninstallTotals {
        let selected = selectedRemovals(selection)
        let chosen = Set(selected.map(\.path))
        let kept = removals.filter { !chosen.contains($0.path) }
        return UninstallTotals(
            count: selected.count,
            bytes: selected.reduce(0) { $0 + ($1.sizeBytes ?? 0) },
            bytesArePartial: selected.contains { $0.sizeBytes == nil || $0.sizeIsPartial },
            keptCount: kept.count,
            keptBytes: kept.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
        )
    }

    /// Whether this can be undone, stated truthfully for the mode chosen.
    ///
    /// MacUp itself undoes nothing, so it never says "available". What it
    /// says is what the person can do: take things back out of the Trash
    /// until it is emptied, and reinstall what a package manager removed.
    public func rollback(for mode: RemovalMode) -> RollbackCapability {
        var sentences: [String] = []
        switch mode {
        case .trash:
            sentences.append("MacUp cannot undo this itself. What MacUp moves to the Trash can be put back from the Trash until you empty it.")
        case .delete:
            sentences.append("This cannot be undone. What MacUp deletes permanently is gone.")
        }
        if let manager = steps.isEmpty ? nil : subject.provider?.displayName {
            sentences.append("What \(manager) removes does not go to the Trash; reinstall it with \(manager) to get it back.")
        }
        return RollbackCapability(availability: .unavailable, explanation: sentences.joined(separator: " "))
    }
}
