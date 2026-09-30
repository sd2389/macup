import Darwin
import Foundation

/// The read-only questions the uninstaller asks the file system.
///
/// Everything is answered from `lstat`, so a symbolic link is always seen as
/// the link it is: nothing here follows a link to find out what is "really"
/// there, lists a directory through one, or counts the size of what one
/// points at. Nothing here changes anything either — removal lives in one
/// place only (``GuardedFileRemover``).
enum FileTree {
    /// What `lstat` says about one path.
    struct Status: Sendable, Hashable {
        var identity: FileIdentity
        var owner: uid_t
        var mode: mode_t
        var flags: UInt32
        var linkCount: UInt16

        var kind: FileKind { identity.kind }
        var isLocked: Bool { flags & FileTree.lockedFlags != 0 }
    }

    /// `UF_IMMUTABLE`, `UF_APPEND`, `SF_IMMUTABLE`, `SF_APPEND`,
    /// `SF_RESTRICTED` (System Integrity Protection), and `SF_NOUNLINK`: any
    /// of them means the item cannot be removed by its owner as it stands.
    static let lockedFlags: UInt32 = 0x0000_0002 | 0x0000_0004 | 0x0002_0000 | 0x0004_0000 | 0x0008_0000 | 0x0010_0000

    static func status(_ path: String) -> Status? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Status(
            identity: FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino), kind: kind(info.st_mode)),
            owner: info.st_uid,
            mode: info.st_mode,
            flags: info.st_flags,
            linkCount: info.st_nlink
        )
    }

    static func kind(_ mode: mode_t) -> FileKind {
        switch mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        case S_IFLNK: .symlink
        default: .other
        }
    }

    static func exists(_ path: String) -> Bool { status(path) != nil }

    /// A real directory — not a link to one.
    static func isDirectory(_ path: String) -> Bool { status(path)?.kind == .directory }

    /// The names in a directory, when it is a real directory (never a link
    /// to one) that MacUp can read. Hidden names are included; sorted, so a
    /// scan reads the same every time.
    static func names(in directory: String) -> [String]? {
        guard isDirectory(directory) else { return nil }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        return names.sorted()
    }

    /// `path` with every link resolved, or `nil` when it does not exist.
    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Where the item at `path` actually lives: its parent directory with
    /// every link resolved, and its own name. The item itself is not
    /// resolved, so a link is located where the link is, while a link
    /// anywhere above it — a folder that is secretly somewhere else — is
    /// followed and seen for what it is.
    static func canonicalLocation(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        guard !name.isEmpty, name != ".", name != "..", let canonicalParent = canonicalPath(parent) else { return nil }
        return canonicalParent == "/" ? "/" + name : canonicalParent + "/" + name
    }

    /// Whether the current user may write `path`: create and remove what is
    /// in it, for a directory.
    static func isWritable(_ path: String) -> Bool {
        access(path, W_OK) == 0
    }

    /// Whether the volume `path` is on is mounted read-only, as the sealed
    /// system volume is.
    static func isOnReadOnlyVolume(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        return info.f_flags & UInt32(MNT_RDONLY) != 0
    }

    /// Whether `path` is an absolute, already-standardized path: no `.` or
    /// `..` component, no empty component, no trailing slash, and nothing a
    /// terminal would not show.
    static func isPlainAbsolute(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count > 1, !path.hasSuffix("/"), !path.contains("//"), !path.contains("\0") else {
            return false
        }
        if path.unicodeScalars.contains(where: TerminalText.isUnsafe) { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains { $0 == "." || $0 == ".." || $0.isEmpty }
    }

    /// Whether `path` is strictly inside `directory`.
    static func isInside(_ path: String, _ directory: String) -> Bool {
        let root = directory == "/" ? "/" : directory + "/"
        return path.hasPrefix(root) && path.count > root.count
    }

    /// Whether `path` is `directory` or inside it.
    static func isWithin(_ path: String, _ directory: String) -> Bool {
        path == directory || isInside(path, directory)
    }

    /// A property list that is a dictionary, read with a size limit, or
    /// `nil`. Reading follows no link: a property list MacUp was not given
    /// directly is not one it trusts to describe anything.
    static func propertyList(_ path: String, maximumBytes: Int = 1 << 20) -> [String: Any]? {
        guard status(path)?.kind == .file,
              let data = LocalFileSystem().contents(atPath: path, maximumBytes: maximumBytes),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return object as? [String: Any]
    }

    // MARK: Size

    /// What walking a file or folder found.
    struct SizeReading: Sendable, Hashable {
        /// Allocated bytes, as `du` counts them, with each hard-linked file
        /// counted once.
        var bytes: Int64 = 0
        var entries = 0
        /// The walk stopped at its limit, so ``bytes`` is a lower bound.
        var partial = false
        /// Entries MacUp could not read, so their size is not included.
        var unreadable = 0
        /// Entries the current user cannot remove: folders they cannot write
        /// and files macOS has locked. Any at all means MacUp will not remove
        /// the item, because it would be left half-removed.
        var locked = 0
        /// Folders inside it where another disk is mounted. The walk does not
        /// enter them, and MacUp removes nothing that holds one.
        var otherVolumes = 0
    }

    /// Walks `path` without following links or leaving its volume, and adds
    /// up what it holds.
    static func size(of path: String, entryLimit: Int = 2_000_000) -> SizeReading? {
        guard let top = status(path) else { return nil }
        var reading = SizeReading()
        guard top.kind == .directory else {
            var info = stat()
            if lstat(path, &info) == 0 { reading.bytes = Int64(info.st_blocks) * 512 }
            reading.entries = 1
            if top.isLocked { reading.locked = 1 }
            return reading
        }
        guard let copy = strdup(path) else { return nil }
        defer { free(copy) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [copy, nil]
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
        defer { fts_close(stream) }

        struct Inode: Hashable {
            var device: Int32
            var inode: UInt64
        }
        var seen = Set<Inode>()
        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_DP { continue }
            if info == FTS_DNR || info == FTS_ERR || info == FTS_NS {
                reading.unreadable += 1
                continue
            }
            guard let stat = entry.pointee.fts_statp?.pointee else { continue }
            reading.entries += 1
            if reading.entries > entryLimit {
                reading.partial = true
                break
            }
            if Int64(stat.st_dev) != top.identity.device { reading.otherVolumes += 1 }
            if stat.st_flags & lockedFlags != 0 { reading.locked += 1 }
            if info == FTS_D, access(entry.pointee.fts_path, W_OK) != 0 { reading.locked += 1 }
            if stat.st_nlink > 1 && (stat.st_mode & S_IFMT) != S_IFDIR {
                guard seen.insert(Inode(device: stat.st_dev, inode: UInt64(stat.st_ino))).inserted else { continue }
            }
            reading.bytes += Int64(stat.st_blocks) * 512
        }
        return reading
    }
}
