import Darwin
import Foundation
import MacUpCore

/// A pretend Mac inside a temporary folder, for the uninstaller's tests.
///
/// Everything the uninstaller reads or removes is under ``root``: a home
/// folder with a Library, two Applications folders, a system Library, and a
/// receipts folder. Removal goes through ``trash`` (a fake Trash folder inside
/// the root) or deletes inside the root, so no test can reach the real Trash
/// or anything outside its own temporary folder (CLAUDE.md §20).
public final class UninstallFixture: @unchecked Sendable {
    public let directory: TemporaryDirectory
    public let root: String
    public let backend: FakeRemovalBackend
    public let running = FakeRunningApplications()
    public let signatures = FakeCodeSignatures()
    public let keychain = FakeKeychainItems()

    public init() throws {
        directory = try TemporaryDirectory(prefix: "macup-uninstall")
        root = directory.canonicalPath
        backend = FakeRemovalBackend(root: root, trash: root + "/Trash")
        for folder in [
            "home/Library/Caches", "home/Library/Preferences/ByHost", "home/Library/Saved Application State",
            "home/Library/HTTPStorages", "home/Library/WebKit", "home/Library/Logs", "home/Library/Cookies",
            "home/Library/Application Scripts", "home/Library/LaunchAgents", "home/Library/Application Support",
            "home/Library/Containers", "home/Library/Group Containers", "home/Applications", "home/.config",
            "home/.local/state", "home/.local/bin", "Applications", "SystemLibrary/Application Support",
            "SystemLibrary/LaunchDaemons", "SystemLibrary/LaunchAgents", "receipts", "Trash",
        ] {
            try FileManager.default.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
        }
    }

    deinit {
        // Anything a test locked or made read-only is opened again so the
        // temporary folder can be removed.
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            for case let relative as String in enumerator {
                let path = root + "/" + relative
                chflags(path, 0)
                chmod(path, 0o755)
            }
        }
    }

    public var home: String { root + "/home" }
    public var library: String { home + "/Library" }
    public var applications: String { root + "/Applications" }
    public var userApplications: String { home + "/Applications" }

    public var paths: MacUpPaths { MacUpPaths.standard(homeDirectory: home) }

    /// The uninstall environment for this pretend Mac. Nothing in it is the
    /// real one: no real running-apps list, signature, Keychain, or Trash.
    public func environment(currentAppBundle: String? = nil, remover: GuardedFileRemover? = nil) -> UninstallEnvironment {
        UninstallEnvironment(
            homeDirectory: home,
            applicationDirectories: [applications, userApplications],
            systemLibrary: root + "/SystemLibrary",
            receiptsDirectory: root + "/receipts",
            pythonFramework: root + "/SystemLibrary/Frameworks/Python.framework",
            macUpCommandLocations: [home + "/.local/bin/macup", root + "/usr-local-bin/macup"],
            currentAppBundle: currentAppBundle,
            // The temporary folder is under /private, so a test's boundary
            // leaves that one prefix out; every other system folder stays.
            systemPrefixes: RemovalBoundary.standardSystemPrefixes.filter { $0 != "/private" && $0 != "/var" },
            userID: getuid(),
            runningApplications: running,
            signatures: signatures,
            keychain: keychain,
            remover: remover ?? GuardedFileRemover(backend: backend)
        )
    }

    // MARK: Building the pretend Mac

    /// Writes an app bundle with an Info.plist, and returns its path.
    @discardableResult
    public func app(
        _ name: String,
        in folder: String? = nil,
        identifier: String?,
        version: String = "1.0",
        bundleName: String? = nil,
        appStore: Bool = false,
        bytes: Int = 4096
    ) throws -> String {
        let path = (folder ?? applications) + "/" + name + ".app"
        try FileManager.default.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleShortVersionString": version]
        if let identifier { info["CFBundleIdentifier"] = identifier }
        if let bundleName { info["CFBundleName"] = bundleName }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        try Data(repeating: 1, count: bytes).write(to: URL(fileURLWithPath: path + "/Contents/MacOS/" + name))
        if appStore {
            try FileManager.default.createDirectory(atPath: path + "/Contents/_MASReceipt", withIntermediateDirectories: true)
            try Data("receipt".utf8).write(to: URL(fileURLWithPath: path + "/Contents/_MASReceipt/receipt"))
        }
        return path
    }

    /// Writes a file (and the folders above it) under the root.
    @discardableResult
    public func file(_ relative: String, _ contents: String = "x") throws -> String {
        let path = relative.hasPrefix("/") ? relative : root + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Makes a folder (and the folders above it) under the root.
    @discardableResult
    public func folder(_ relative: String) throws -> String {
        let path = relative.hasPrefix("/") ? relative : root + "/" + relative
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Writes a launchd property list.
    @discardableResult
    public func launchAgent(_ path: String, label: String, program: String) throws -> String {
        let plist: [String: Any] = ["Label": label, "ProgramArguments": [program]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    public func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}

/// The Trash and deletion, confined to a test's temporary folder.
///
/// "Moving to the Trash" renames the item into a folder inside the fixture;
/// deleting removes it. Both refuse anything outside the fixture's root, so a
/// test that got its paths wrong fails instead of touching the Mac.
public final class FakeRemovalBackend: FileRemovalBackend, @unchecked Sendable {
    public let root: String
    public let trash: String
    private let lock = NSLock()
    private var _trashed: [String] = []
    private var _deleted: [String] = []
    /// Paths the next call should fail on, as a permission error would.
    public var failing: Set<String> = []

    public init(root: String, trash: String) {
        self.root = root
        self.trash = trash
    }

    public var trashed: [String] { lock.withLock { _trashed } }
    public var deleted: [String] { lock.withLock { _deleted } }

    private func check(_ path: String) throws {
        guard path.hasPrefix(root + "/"), !path.hasPrefix(trash + "/") else {
            throw NSError(domain: "FakeRemovalBackend", code: 1, userInfo: [NSLocalizedDescriptionKey: "outside the test's folder"])
        }
        if lock.withLock({ failing.contains(path) }) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [NSLocalizedDescriptionKey: "permission denied"])
        }
    }

    public func moveToTrash(_ path: String) throws -> String? {
        try check(path)
        let destination = trash + "/" + UUID().uuidString + "-" + (path as NSString).lastPathComponent
        guard rename(path, destination) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        lock.withLock { _trashed.append(path) }
        return destination
    }

    public func deletePermanently(_ path: String) throws {
        try check(path)
        try FileManager.default.removeItem(atPath: path)
        lock.withLock { _deleted.append(path) }
    }
}

/// Which apps a test says are open.
public final class FakeRunningApplications: RunningApplicationChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var open: [String: String] = [:]

    public init() {}

    /// Marks the app at `path` (or with this identifier) as open.
    public func open(_ key: String, name: String) {
        lock.withLock { open[key] = name }
    }

    public func quitAll() {
        lock.withLock { open = [:] }
    }

    public func running(bundleIdentifier: String?, bundlePath: String) async -> [RunningApplication] {
        lock.withLock {
            [bundlePath, bundleIdentifier].compactMap { $0 }.compactMap { open[$0] }.map {
                RunningApplication(name: $0, processIdentifier: 4242)
            }
        }
    }
}

/// Signatures a test describes, by bundle path.
public final class FakeCodeSignatures: CodeSignatureReading, @unchecked Sendable {
    private let lock = NSLock()
    private var teams: [String: String] = [:]

    public init() {}

    public func sign(_ path: String, team: String) {
        lock.withLock { teams[path] = team }
    }

    public func teamIdentifier(ofBundleAt path: String) -> String? {
        lock.withLock { teams[path] }
    }
}

/// A Keychain with, at most, MacUp's one leftover item in it.
public final class FakeKeychainItems: MacUpKeychainItemStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var present = false

    public init() {}

    public func saveLeftover() {
        lock.withLock { present = true }
    }

    public func hasLeftoverItem() -> Bool {
        lock.withLock { present }
    }

    public func deleteLeftoverItem() throws -> Bool {
        lock.withLock {
            defer { present = false }
            return present
        }
    }
}

