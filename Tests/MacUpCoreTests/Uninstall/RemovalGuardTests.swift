import Darwin
import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// The only way an uninstall removes a file, and the boundary it checks every
/// path against immediately before removing it.
@Suite("Uninstall: the removal guard")
struct RemovalGuardTests {
    // MARK: The boundary on a real Mac

    private let home = "/Users/example"
    private var standard: RemovalBoundary {
        RemovalBoundary.standard(
            homeDirectory: home,
            applicationDirectories: ["/Applications", home + "/Applications"],
            homebrewPrefix: "/opt/homebrew",
            exactFiles: ["/usr/local/bin/macup"]
        )
    }

    @Test("The folders a Mac is built around are never removed", arguments: [
        "/Users/example", "/Users/example/Library", "/Users/example/Library/Caches",
        "/Users/example/Library/Application Support", "/Users/example/Library/Preferences",
        "/Users/example/.Trash", "/Users/example/.Trash/old.app", "/Users/example/Documents", "/Users/example/Desktop",
        "/Users/example/.config", "/Users/example/.local/state", "/Applications", "/Users/example/Applications",
        "/System/Applications/Safari.app", "/System/Library/CoreServices", "/usr/bin/ssh", "/usr/local/bin/brew",
        "/bin/zsh", "/sbin/mount", "/private/etc/hosts", "/private/var/db/receipts/com.example.pkg.plist",
        "/Library/LaunchDaemons/com.example.plist", "/Library/Application Support/com.example", "/etc/hosts",
        "/opt/homebrew/Cellar/mysql", "/opt/homebrew/var", "/opt/homebrew/etc", "/opt/homebrew/bin/mysql",
        "/Volumes/Backup/file", "/",
        "/Users/example/Library/Mobile Documents", "/Users/example/Library/Mobile Documents/com~apple~CloudDocs",
    ])
    func refusesProtected(_ path: String) {
        #expect(standard.refusal(for: path) != nil, "\(path) must be refused")
    }

    @Test("What an uninstall may remove is allowed", arguments: [
        "/Users/example/Library/Caches/com.openai.chat", "/Users/example/Library/Preferences/com.openai.chat.plist",
        "/Users/example/Library/Application Support/Claude", "/Users/example/.codex", "/Users/example/.config/macup",
        "/Applications/ChatGPT.app", "/Applications/Utilities/Helper.app", "/Users/example/Applications/Mine.app",
        "/opt/homebrew/var/mysql", "/opt/homebrew/etc/redis.conf", "/usr/local/bin/macup",
    ])
    func allows(_ path: String) {
        #expect(standard.refusal(for: path) == nil, "\(path) should be removable: \(standard.refusal(for: path) ?? "")")
    }

    @Test("Inside Applications only an app bundle may go, never what is inside one or a plain folder")
    func applicationsHoldOnlyApps() {
        #expect(standard.refusal(for: "/Applications/Utilities") != nil)
        #expect(standard.refusal(for: "/Applications/ChatGPT.app/Contents") != nil)
        #expect(standard.refusal(for: "/Applications/notes.txt") != nil)
        #expect(standard.refusal(for: "/Applications/A/B/C.app") != nil)
    }

    @Test("A path with dot components, a relative path, or control characters is refused before anything else")
    func refusesUnplainPaths() {
        for path in ["/Users/example/Library/Caches/../Preferences", "/Users/example/./x", "Library/Caches/x",
                     "/Users/example/Library/Caches/x\u{1B}[31m", "/Users/example//x", "/Users/example/x/"] {
            #expect(standard.refusal(for: path) != nil, "\(path.debugDescription)")
        }
    }

    @Test("A Homebrew prefix MacUp cannot reason about opens nothing up")
    func unusablePrefixes() {
        for prefix in ["/", "/usr", "/Users/example", "relative"] {
            let boundary = RemovalBoundary.standard(homeDirectory: home, applicationDirectories: ["/Applications"], homebrewPrefix: prefix)
            #expect(boundary.usableHomebrewPrefix == nil, "\(prefix)")
            #expect(boundary.refusal(for: "/var/mysql") != nil)
        }
    }

    @Test("MacUp's own command outside the home folder is removable only by an uninstall of MacUp")
    func exactFilesAreForMacUpOnly() {
        let other = RemovalBoundary.standard(homeDirectory: home, applicationDirectories: ["/Applications"], homebrewPrefix: "/usr/local")
        #expect(other.refusal(for: "/usr/local/bin/macup") != nil)
        let own = RemovalBoundary.standard(
            homeDirectory: home,
            applicationDirectories: ["/Applications"],
            homebrewPrefix: "/usr/local",
            exactFiles: ["/usr/local/bin/macup"]
        )
        #expect(own.refusal(for: "/usr/local/bin/macup") == nil)
        #expect(own.refusal(for: "/usr/local/bin/brew") != nil)
        #expect(own.refusal(for: "/usr/local/var/mysql") == nil, "Intel Homebrew's data folders")
    }

    // MARK: Removing, in a temporary folder

    private func planned(_ path: String, category: LeftoverCategory = .belongsToApp) -> PlannedRemoval {
        let status = FileTree.status(path)
        return PlannedRemoval(
            path: path,
            category: category,
            kind: status?.kind ?? .file,
            sizeBytes: 1,
            selectedByDefault: true,
            reason: "test",
            identity: status?.identity
        )
    }

    @Test("Move to Trash moves the item, and Delete Permanently deletes it, both confirmed gone")
    func trashAndDelete() throws {
        let mac = try UninstallFixture()
        let boundary = mac.environment().boundary(homebrewPrefix: nil, forMacUp: false)
        let remover = GuardedFileRemover(backend: mac.backend)
        let one = try mac.file("home/Library/Caches/com.example/one")
        let cache = (one as NSString).deletingLastPathComponent
        let preference = try mac.file("home/Library/Preferences/com.example.plist")

        let trashed = remover.remove(planned(cache), mode: .trash, within: boundary)
        #expect(trashed.status == .removed)
        #expect(trashed.trashedTo?.hasPrefix(mac.root + "/Trash/") == true)
        #expect(!mac.exists(cache))
        #expect(mac.backend.trashed == [cache])

        let deleted = remover.remove(planned(preference), mode: .delete, within: boundary)
        #expect(deleted.status == .removed)
        #expect(deleted.trashedTo == nil)
        #expect(!mac.exists(preference))
        #expect(mac.backend.deleted == [preference])
    }

    @Test("A path that changed since the plan was made is skipped, not removed")
    func changedSincePlanning() throws {
        let mac = try UninstallFixture()
        let boundary = mac.environment().boundary(homebrewPrefix: nil, forMacUp: false)
        let path = try mac.file("home/Library/Caches/com.example.plist")
        let before = planned(path)
        try FileManager.default.removeItem(atPath: path)
        try mac.file("home/Library/Caches/com.example.plist", "a different file now")
        let outcome = GuardedFileRemover(backend: mac.backend).remove(before, mode: .delete, within: boundary)
        #expect(outcome.status == .skipped)
        #expect(outcome.reason?.contains("changed since you reviewed it") == true)
        #expect(mac.exists(path))
    }

    @Test("A file swapped for a link after planning is skipped, and the link's target is untouched")
    func swappedForALink() throws {
        let mac = try UninstallFixture()
        let boundary = mac.environment().boundary(homebrewPrefix: nil, forMacUp: false)
        let path = try mac.file("home/Library/Caches/com.example.data")
        let before = planned(path)
        let precious = try mac.file("home/Documents/precious.txt")
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: precious)
        let outcome = GuardedFileRemover(backend: mac.backend).remove(before, mode: .delete, within: boundary)
        #expect(outcome.status == .skipped)
        #expect(mac.exists(precious))
    }

    @Test("A link is removed as a link and what it points at stays")
    func linksAreRemovedAsLinks() throws {
        let mac = try UninstallFixture()
        let boundary = mac.environment().boundary(homebrewPrefix: nil, forMacUp: false)
        let target = try mac.file("home/Documents/keep.txt")
        let link = mac.home + "/Library/Caches/com.example.link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        for mode in RemovalMode.allCases {
            if !mac.exists(link) { try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target) }
            let outcome = GuardedFileRemover(backend: mac.backend).remove(planned(link), mode: mode, within: boundary)
            #expect(outcome.status == .removed)
            #expect(!mac.exists(link))
            #expect(mac.exists(target), "the link's target must survive \(mode)")
        }
    }

    @Test("A folder that leads out of the home folder through a link is refused")
    func symlinkEscapes() throws {
        let mac = try UninstallFixture()
        let boundary = mac.environment().boundary(homebrewPrefix: nil, forMacUp: false)
        let outside = try mac.folder("outside")
        try mac.file("outside/victim")
        try FileManager.default.createSymbolicLink(atPath: mac.home + "/Library/Caches/escape", withDestinationPath: outside)
        let escaped = mac.home + "/Library/Caches/escape/victim"
        let outcome = GuardedFileRemover(backend: mac.backend).remove(planned(escaped), mode: .delete, within: boundary)
        #expect(outcome.status == .skipped)
        #expect(outcome.reason?.contains("really at") == true)
        #expect(mac.exists(outside + "/victim"))
    }

    @Test("The guard refuses every protected folder even when it is handed one", arguments: ["", "/Library", "/Library/Caches", "/.Trash", "/Documents"])
    func handedAProtectedFolder(_ relative: String) throws {
        let mac = try UninstallFixture()
        try mac.folder("home/.Trash")
        try mac.folder("home/Documents")
        let path = mac.home + relative
        let boundary = mac.environment().boundary(homebrewPrefix: nil, forMacUp: false)
        let outcome = GuardedFileRemover(backend: mac.backend).remove(planned(path), mode: .delete, within: boundary)
        #expect(outcome.status == .skipped)
        #expect(mac.exists(path))
        #expect(mac.backend.deleted.isEmpty && mac.backend.trashed.isEmpty)
    }

    @Test("Something already gone is reported as gone, and something macOS has locked is left alone")
    func goneAndLocked() throws {
        let mac = try UninstallFixture()
        let boundary = mac.environment().boundary(homebrewPrefix: nil, forMacUp: false)
        let gone = planned(mac.home + "/Library/Caches/never-there")
        #expect(GuardedFileRemover(backend: mac.backend).remove(gone, mode: .trash, within: boundary).status == .alreadyGone)

        let locked = try mac.file("home/Library/Caches/com.example.locked")
        #expect(chflags(locked, UInt32(UF_IMMUTABLE)) == 0)
        let outcome = GuardedFileRemover(backend: mac.backend).remove(planned(locked), mode: .delete, within: boundary)
        #expect(outcome.status == .skipped)
        #expect(outcome.reason?.contains("locked") == true)
    }

    @Test("A removal the operating system refuses is a failure, and the item is reported as still there")
    func backendFailure() throws {
        let mac = try UninstallFixture()
        let boundary = mac.environment().boundary(homebrewPrefix: nil, forMacUp: false)
        let path = try mac.file("home/Library/Caches/com.example.refused")
        mac.backend.failing = [path]
        let outcome = GuardedFileRemover(backend: mac.backend).remove(planned(path), mode: .trash, within: boundary)
        #expect(outcome.status == .failed)
        #expect(mac.exists(path))
    }
}
