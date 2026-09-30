import Foundation

/// What an app may have left in places only an administrator can change:
/// `/Library` and the installer-package receipts. MacUp removes none of it —
/// it never runs as root and never asks for a password — so each one is
/// listed with the exact steps to remove it by hand.
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
    var userID: uid_t

    func scan(bundleIdentifier: String?, bundlePath: String) -> [ManualRemoval] {
        var found: [ManualRemoval] = []
        let bundle = FileTree.canonicalPath(bundlePath) ?? bundlePath
        // A bundle identifier too short to name one app's files names none.
        let bundleIdentifier = bundleIdentifier.flatMap { AppLeftoverScanner.scope(of: $0) == .tooBroad ? nil : $0 }
        if let identifier = bundleIdentifier {
            for folder in ["Application Support", "Caches", "Preferences", "PrivilegedHelperTools"] {
                let directory = systemLibrary + "/" + folder
                for name in (FileTree.names(in: directory) ?? [])
                where AppLeftoverScanner.name(name, belongsTo: identifier, notTo: otherBundleIdentifiers) {
                    found.append(Self.file(directory + "/" + name))
                }
            }
            for name in FileTree.names(in: receiptsDirectory) ?? [] {
                let receipt = name.hasSuffix(".plist") ? String(name.dropLast(6)) : name.hasSuffix(".bom") ? String(name.dropLast(4)) : nil
                guard let receipt, name.hasSuffix(".plist"),
                      AppLeftoverScanner.name(receipt, belongsTo: identifier, notTo: otherBundleIdentifiers)
                else { continue }
                found.append(Self.receipt(receipt, path: receiptsDirectory + "/" + name))
            }
        }
        for (folder, domain) in [("LaunchDaemons", "system"), ("LaunchAgents", "gui/\(userID)")] {
            let directory = systemLibrary + "/" + folder
            for name in FileTree.names(in: directory) ?? [] where name.hasSuffix(".plist") {
                let path = directory + "/" + name
                guard let agent = LaunchAgentFile(path: path) else { continue }
                let labelled = bundleIdentifier.map { identifier in
                    agent.label.map { AppLeftoverScanner.name($0, belongsTo: identifier, notTo: otherBundleIdentifiers) } ?? false
                } ?? false
                guard labelled || agent.startsProgram(inside: bundle) else { continue }
                found.append(Self.job(path, label: agent.label, domain: domain))
            }
        }
        return found
    }

    static let administratorReason = "Removing it needs an administrator, and MacUp never asks for a password."

    static func file(_ path: String) -> ManualRemoval {
        ManualRemoval(
            path: path,
            reason: administratorReason,
            steps: ["In Finder, choose Go → Go to Folder, enter \(quoted(path)), move it to the Trash, and enter an administrator's password when macOS asks."]
        )
    }

    static func receipt(_ identifier: String, path: String) -> ManualRemoval {
        ManualRemoval(
            path: path,
            reason: "macOS keeps this record of the app's installer package. " + administratorReason,
            steps: ["In Terminal, run: sudo pkgutil --forget \(quoted(identifier))"]
        )
    }

    static func job(_ path: String, label: String?, domain: String) -> ManualRemoval {
        var steps: [String] = []
        if let label {
            let prefix = domain == "system" ? "sudo " : ""
            steps.append("In Terminal, stop it: \(prefix)launchctl bootout \(quoted(domain + "/" + label))")
        }
        steps.append("Then remove the file: sudo rm \(quoted(path))")
        return ManualRemoval(
            path: path,
            reason: "A launchd job for the whole Mac, which starts this app's helper. " + administratorReason,
            steps: steps
        )
    }

    /// A path or name as it would be typed into a shell: quoted when it needs
    /// to be, so pasting it cannot do more than it says.
    static func quoted(_ text: String) -> String {
        CommandInvocation.quoted(text)
    }
}
