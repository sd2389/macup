import Darwin
import Foundation

/// What happened to one path an uninstall set out to remove.
public struct RemovalOutcome: Sendable, Hashable, Codable, Identifiable {
    public enum Status: String, Sendable, Hashable, Codable {
        /// Moved to the Trash or deleted, and confirmed gone.
        case removed
        /// It was not there any more when MacUp came to remove it.
        case alreadyGone
        /// MacUp decided not to remove it, for the reason given.
        case skipped
        /// MacUp tried, and it is still there, or partly there.
        case failed
    }

    public var path: String
    public var category: LeftoverCategory
    public var status: Status
    public var mode: RemovalMode
    /// Where it went, when it went to the Trash.
    public var trashedTo: String?
    /// Why it was skipped or failed.
    public var reason: String?
    public var sizeBytes: Int64?

    public init(
        path: String,
        category: LeftoverCategory,
        status: Status,
        mode: RemovalMode,
        trashedTo: String? = nil,
        reason: String? = nil,
        sizeBytes: Int64? = nil
    ) {
        self.path = path
        self.category = category
        self.status = status
        self.mode = mode
        self.trashedTo = trashedTo
        self.reason = reason
        self.sizeBytes = sizeBytes
    }

    public var id: String { path }
}

/// The two operating-system calls that remove something. Behind a protocol
/// so no test ever touches the real Trash.
public protocol FileRemovalBackend: Sendable {
    /// Moves the item to the Trash and returns where it went.
    func moveToTrash(_ path: String) throws -> String?
    func deletePermanently(_ path: String) throws
}

/// The Trash and the file system, through `FileManager`.
///
/// These are the only calls in MacUp that remove a file for an uninstall,
/// and `scripts/check-trust-invariants.sh` fails the build if either appears
/// anywhere else. Neither follows a link: `trashItem` moves the link itself,
/// and `removeItem` removes a link rather than what it points at.
public struct SystemFileRemovalBackend: FileRemovalBackend {
    public init() {}

    public func moveToTrash(_ path: String) throws -> String? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return resulting?.path
    }

    public func deletePermanently(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }
}

/// The only way an uninstall removes a file.
///
/// It removes exactly the path it is handed from a confirmed plan, and first
/// checks again, immediately before removing it, everything the plan assumed:
///
/// - the path is still there (if not, that is reported, not an error);
/// - it is still the same file — same device, inode, and kind as when the
///   plan was made — so something swapped in since, including a link, is
///   skipped;
/// - where it really lives, with every link above it resolved, is inside the
///   ``RemovalBoundary``;
/// - it is not a separate volume mounted there, and macOS has not locked it;
/// - a folder a cask removes only when empty is empty;
/// - a folder being deleted permanently has no other disk mounted inside it.
///
/// A link is removed as a link and never followed. Anything that fails a
/// check is skipped and reported with the reason; nothing is adjusted into a
/// path that would pass.
public struct GuardedFileRemover: Sendable {
    public var backend: any FileRemovalBackend

    public init(backend: any FileRemovalBackend = SystemFileRemovalBackend()) {
        self.backend = backend
    }

    public func remove(_ removal: PlannedRemoval, mode: RemovalMode, within boundary: RemovalBoundary) -> RemovalOutcome {
        let path = removal.path
        func outcome(_ status: RemovalOutcome.Status, _ reason: String? = nil, trashedTo: String? = nil) -> RemovalOutcome {
            RemovalOutcome(
                path: path,
                category: removal.category,
                status: status,
                mode: mode,
                trashedTo: trashedTo,
                reason: reason,
                sizeBytes: status == .removed ? removal.sizeBytes : nil
            )
        }

        guard FileTree.isPlainAbsolute(path) else {
            return outcome(.skipped, "MacUp did not remove it because it is not a plain, absolute path.")
        }
        guard let current = FileTree.status(path) else {
            return outcome(.alreadyGone, "It was already gone.")
        }
        if let planned = removal.identity, planned != current.identity {
            return outcome(.skipped, "MacUp did not remove it because it has changed since you reviewed it.")
        }
        guard current.kind == removal.kind else {
            return outcome(.skipped, "MacUp did not remove it because it is no longer the kind of item you reviewed.")
        }
        guard let location = FileTree.canonicalLocation(path) else {
            return outcome(.skipped, "MacUp did not remove it because it could not tell where it really is.")
        }
        if let refusal = boundary.refusal(for: location) {
            let moved = location == path ? "" : " (it is really at \(PathDisplay.abbreviatingHome(location, homeDirectory: boundary.homeDirectory)))"
            return outcome(.skipped, "MacUp did not remove it because \(refusal)\(moved).")
        }
        if current.kind == .directory, let parent = FileTree.status((path as NSString).deletingLastPathComponent),
           parent.identity.device != current.identity.device {
            return outcome(.skipped, "MacUp did not remove it because it is a separate volume.")
        }
        if current.isLocked {
            return outcome(.skipped, "MacUp did not remove it because macOS has locked it.")
        }
        if removal.onlyIfEmpty {
            guard current.kind == .directory, let names = FileTree.names(in: path), names.allSatisfy({ $0 == ".DS_Store" }) else {
                return outcome(.skipped, "MacUp did not remove it because it is not empty, and it is removed only when it is.")
            }
        }
        // Deleting a folder deletes everything below it, so a disk mounted
        // anywhere inside must not be reached. Moving it to the Trash moves
        // the folder alone and reaches into nothing.
        if mode == .delete, current.kind == .directory {
            guard let inside = FileTree.size(of: path), !inside.partial else {
                return outcome(.skipped, "MacUp did not delete it because it could not check everything inside it. Moving it to the Trash instead is safe.")
            }
            if inside.otherVolumes > 0 {
                return outcome(.skipped, "MacUp did not delete it because another disk is mounted inside it.")
            }
        }

        // A link is moved or deleted as a link. What it pointed at is noted
        // first, so that if moving it ever took the target with it, the
        // result says so rather than claiming a clean removal.
        let linkTarget = current.kind == .symlink ? FileTree.canonicalPath(path) : nil
        var trashedTo: String?
        do {
            switch mode {
            case .trash: trashedTo = try backend.moveToTrash(path)
            case .delete: try backend.deletePermanently(path)
            }
        } catch {
            let reason = (error as NSError).localizedDescription
            let partly = FileTree.exists(path) && current.kind == .directory
                ? " Some of what was inside it may already be gone."
                : ""
            return outcome(.failed, "MacUp could not remove it: \(TerminalText.sanitize(reason)).\(partly)")
        }
        if FileTree.exists(path) {
            return outcome(.failed, "It was still there after MacUp removed it.", trashedTo: trashedTo)
        }
        if let linkTarget, !FileTree.exists(linkTarget) {
            return outcome(
                .removed,
                "The link was removed, and what it pointed at is no longer where it was.",
                trashedTo: trashedTo
            )
        }
        return outcome(.removed, trashedTo: trashedTo)
    }
}
