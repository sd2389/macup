import Foundation

/// What an app may have left in places only an administrator can change:
/// `/Library` and the installer-package receipts. MacUp removes none of it —
/// it never runs as root and never asks for a password — so each one is
/// listed with the exact steps to remove it by hand.
///
/// Nothing found here is ever removed, so these folders are read by wider
/// rules than the home folder's Library, where a match becomes a file MacUp
/// deletes. Three rules, strongest first:
///
/// - the bundle identifier, or a name starting with it and a dot, as in the
///   home folder — `com.teamviewer.TeamViewer.plist`;
/// - the maker's namespace, the identifier's first two parts, which is how an
///   installer names the helpers, daemons, and receipts it calls after itself
///   rather than after the app — `com.teamviewer.Helper`,
///   `com.teamviewer.teamviewerPriviledgedHelper`;
/// - a folder named exactly like the app — `/Library/Application Support/TeamViewer`.
///
/// Each match says which rule found it, and the two weaker rules say to check
/// before removing. A name that another installed app's identifier claims
/// more exactly, or a folder named after another installed app, is left to
/// that app; when another installed app shares the maker's namespace, the
/// reason says so rather than claiming the file.
///
/// This file only reads those folders. It is the one place in MacUp allowed
/// to name the system's launch daemon folder, and only so it can say what is
/// there (`scripts/check-trust-invariants.sh`).
struct SystemLeftoverScanner: Sendable {
    /// `/Library` on a real Mac.
    var systemLibrary: String
    /// `/private/var/db/receipts` on a real Mac.
    var receiptsDirectory: String
    var otherBundleIdentifiers: Set<String>
    /// What the other installed apps are called, so a folder named after one
    /// of them is left to it.
    var otherNames: Set<String> = []
    var userID: uid_t

    /// The folders in `/Library` an app's installer writes to.
    static let folders = ["Application Support", "Caches", "Preferences", "PrivilegedHelperTools"]

    func scan(bundleIdentifier: String?, bundlePath: String, names: [String] = []) -> [ManualRemoval] {
        var found: [ManualRemoval] = []
        var paths = Set<String>()
        func add(_ removal: ManualRemoval) {
            guard paths.insert(removal.path).inserted else { return }
            found.append(removal)
        }
        let bundle = FileTree.canonicalPath(bundlePath) ?? bundlePath
        // A bundle identifier too short to name one app's files names none.
        let bundleIdentifier = bundleIdentifier.flatMap { AppLeftoverScanner.scope(of: $0) == .tooBroad ? nil : $0 }
        let vendor = bundleIdentifier.flatMap(Self.vendorNamespace)
        let sharedVendor = vendor.map { namespace in
            otherBundleIdentifiers.contains { Self.vendorNamespace(of: $0) == namespace }
        } ?? false
        // The folders found here, so a launchd job that starts a program
        // inside one of them is recognised as this app's too.
        var folders: [String] = [bundle]

        for folder in Self.folders {
            let directory = systemLibrary + "/" + folder
            for name in FileTree.names(in: directory) ?? [] {
                let path = directory + "/" + name
                guard let reason = reason(
                    forName: name,
                    identifier: bundleIdentifier,
                    vendor: vendor,
                    sharedVendor: sharedVendor,
                    names: names,
                    isDirectory: { FileTree.isDirectory(path) }
                ) else { continue }
                add(Self.file(path, reason: reason))
                if FileTree.isDirectory(path), let canonical = FileTree.canonicalPath(path) { folders.append(canonical) }
            }
        }
        for name in FileTree.names(in: receiptsDirectory) ?? [] where name.hasSuffix(".plist") {
            let receipt = String(name.dropLast(6))
            guard !receipt.isEmpty else { continue }
            if let identifier = bundleIdentifier,
               AppLeftoverScanner.name(receipt, belongsTo: identifier, notTo: otherBundleIdentifiers) {
                add(Self.receipt(receipt, path: receiptsDirectory + "/" + name, reason: nil))
            } else if let vendor, matchesVendor(receipt, vendor) {
                add(Self.receipt(
                    receipt,
                    path: receiptsDirectory + "/" + name,
                    reason: Self.vendorReason(vendor, shared: sharedVendor)
                ))
            }
        }
        for (folder, domain) in [("LaunchDaemons", "system"), ("LaunchAgents", "gui/\(userID)")] {
            let directory = systemLibrary + "/" + folder
            for name in FileTree.names(in: directory) ?? [] where name.hasSuffix(".plist") {
                let path = directory + "/" + name
                guard let agent = LaunchAgentFile(path: path) else { continue }
                if let identifier = bundleIdentifier, let label = agent.label,
                   AppLeftoverScanner.name(label, belongsTo: identifier, notTo: otherBundleIdentifiers) {
                    add(Self.job(path, label: label, domain: domain, detail: "which starts this app's helper."))
                } else if let vendor, let label = agent.label, matchesVendor(label, vendor) {
                    add(Self.job(
                        path,
                        label: label,
                        domain: domain,
                        detail: "labelled after \(vendor), the maker's part of the app's bundle identifier."
                            + (sharedVendor ? " Another installed app has the same maker, so check whose it is." : " Check it is this app's.")
                    ))
                } else if let started = folders.first(where: agent.startsProgram(inside:)) {
                    add(Self.job(
                        path,
                        label: agent.label,
                        domain: domain,
                        detail: "which starts a program inside \((started as NSString).lastPathComponent)."
                    ))
                }
            }
        }
        return found
    }

    /// Which rule, if any, makes an entry in `/Library` this app's, and what
    /// the plan says about it. `isDirectory` is asked only for a name match,
    /// so a folder listing is not walked for nothing.
    private func reason(
        forName name: String,
        identifier: String?,
        vendor: String?,
        sharedVendor: Bool,
        names: [String],
        isDirectory: () -> Bool
    ) -> String? {
        if let identifier, AppLeftoverScanner.name(name, belongsTo: identifier, notTo: otherBundleIdentifiers) {
            return Self.administratorReason
        }
        if let vendor, matchesVendor(name, vendor) {
            return Self.vendorReason(vendor, shared: sharedVendor)
        }
        if matchesName(name, names), isDirectory() {
            return Self.nameReason(name)
        }
        return nil
    }

    /// The maker's part of a bundle identifier: the first two parts of one
    /// specific enough to use, `com.teamviewer` in `com.teamviewer.TeamViewer`.
    /// Nothing for an identifier too short to name one app, or one in Apple's
    /// namespace, where `com.apple` says nothing about who owns a file.
    static func vendorNamespace(of identifier: String) -> String? {
        guard AppLeftoverScanner.scope(of: identifier) == .specific else { return nil }
        let parts = identifier.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return parts[0] + "." + parts[1]
    }

    /// Whether `name` is in the maker's namespace, and no other installed
    /// app's bundle identifier claims it more exactly.
    private func matchesVendor(_ name: String, _ vendor: String) -> Bool {
        guard name == vendor || name.hasPrefix(vendor + ".") else { return false }
        return !otherBundleIdentifiers.contains { name == $0 || name.hasPrefix($0 + ".") }
    }

    /// Whether `name` is exactly what this app is called, and not what
    /// another installed app is called.
    private func matchesName(_ name: String, _ names: [String]) -> Bool {
        name != "." && name != ".." && names.contains(name) && !otherNames.contains(name)
    }

    static let administratorReason = "Removing it needs an administrator, and MacUp never asks for a password."

    static func vendorReason(_ vendor: String, shared: Bool) -> String {
        "Named after \(vendor), the maker's part of the app's bundle identifier, as an installer names its own helpers."
            + (shared ? " Another installed app has the same maker, so check whose it is." : " Check it is this app's.")
            + " " + administratorReason
    }

    static func nameReason(_ name: String) -> String {
        "Named “\(name)”, like the app. Matched by name only; check it is this app's. " + administratorReason
    }

    static func file(_ path: String, reason: String = administratorReason) -> ManualRemoval {
        ManualRemoval(
            path: path,
            reason: reason,
            steps: ["In Finder, choose Go → Go to Folder, enter \(quoted(path)), move it to the Trash, and enter an administrator's password when macOS asks."]
        )
    }

    static func receipt(_ identifier: String, path: String, reason: String?) -> ManualRemoval {
        ManualRemoval(
            path: path,
            reason: "macOS keeps this record of the app's installer package. " + (reason ?? administratorReason),
            steps: ["In Terminal, run: sudo pkgutil --forget \(quoted(identifier))"]
        )
    }

    static func job(_ path: String, label: String?, domain: String, detail: String) -> ManualRemoval {
        var steps: [String] = []
        if let label {
            let prefix = domain == "system" ? "sudo " : ""
            steps.append("In Terminal, stop it: \(prefix)launchctl bootout \(quoted(domain + "/" + label))")
        }
        steps.append("Then remove the file: sudo rm \(quoted(path))")
        return ManualRemoval(
            path: path,
            reason: "A launchd job for the whole Mac, \(detail) " + administratorReason,
            steps: steps
        )
    }

    /// A path or name as it would be typed into a shell: quoted when it needs
    /// to be, so pasting it cannot do more than it says.
    static func quoted(_ text: String) -> String {
        CommandInvocation.quoted(text)
    }
}
