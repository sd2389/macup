import Foundation

/// Parses `brew outdated --json=v2`:
///
/// ```json
/// {"formulae": [{"name": "git", "installed_versions": ["2.43.0"],
///                "current_version": "2.44.0", "pinned": false, "pinned_version": null}],
///  "casks":    [{"name": "firefox", "installed_versions": ["123.0"],
///                "current_version": "124.0", "pinned": false, "pinned_version": null}]}
/// ```
///
/// Formula names are Homebrew's full names (`user/tap/formula` for third-party
/// taps); cask names are tokens. `pinned` is optional (older Homebrew omitted
/// it for casks) and `installed_versions` may be a string or an array.
enum HomebrewOutdatedParser {
    static func parse(_ data: Data, ownership: OwnershipChain?, command: String? = nil) throws -> ProviderListing<UpdateCandidate> {
        guard let document = JSONValue.parse(data) else {
            throw MacUpError.parseFailed("Homebrew's outdated list was not valid JSON.", command: command)
        }
        guard let formulae = document["formulae"]?.arrayValue, let casks = document["casks"]?.arrayValue else {
            throw MacUpError.parseFailed(
                "Homebrew's outdated list did not have the expected \"formulae\" and \"casks\" arrays.",
                command: command
            )
        }

        var listing = ProviderListing<UpdateCandidate>()
        for entry in formulae {
            collect(entry, namespace: .brew, kind: .formula, ownership: ownership, into: &listing)
        }
        for entry in casks {
            collect(entry, namespace: .brewCask, kind: .cask, ownership: ownership, into: &listing)
        }
        return listing
    }

    private static func collect(
        _ entry: JSONValue,
        namespace: PackageNamespace,
        kind: ItemKind,
        ownership: OwnershipChain?,
        into listing: inout ProviderListing<UpdateCandidate>
    ) {
        let label = kind == .formula ? "formula" : "cask"
        guard let name = entry["name"]?.stringValue else {
            listing.findings.append(ProviderSupport.skippedEntry("(unnamed \(label))", provider: .homebrew, reason: "The entry has no name."))
            return
        }
        guard let installedVersions = entry["installed_versions"]?.stringList, !installedVersions.isEmpty,
              let current = entry["current_version"]?.stringValue, !current.isEmpty
        else {
            listing.findings.append(ProviderSupport.skippedEntry(name, provider: .homebrew, reason: "The entry is missing version information."))
            return
        }
        let id: PackageID
        do {
            id = try PackageID(namespace, name)
        } catch let error as PackageID.ValidationError {
            listing.findings.append(ProviderSupport.skippedName(name, reason: error, provider: .homebrew))
            return
        } catch {
            return
        }

        let installed = newest(installedVersions)
        let pinned = entry["pinned"]?.boolValue ?? false
        let pinnedVersion = entry["pinned_version"]?.stringValue

        var signals: Set<RiskSignal> = []
        var notes: [String] = []
        var details: [String: String] = [:]
        if pinned {
            signals.insert(.pinnedByProvider)
            notes.append("Pinned in Homebrew at \(pinnedVersion ?? installed). MacUp never unpins Homebrew items.")
            details["pinnedVersion"] = pinnedVersion
        }
        if kind == .formula && RuntimeCatalog.isRuntime(name) {
            signals.insert(.runtimeOrToolchain)
        }
        if RuntimeCatalog.isPackageManager(name) {
            signals.insert(.packageManagerSelfUpdate)
            notes.append("Updates \(name), which manages other software.")
        }
        if installedVersions.count > 1 {
            details["installedVersions"] = installedVersions.joined(separator: ", ")
            notes.append("Several versions are installed: \(installedVersions.joined(separator: ", ")).")
        }

        listing.elements.append(UpdateCandidate(
            id: id,
            kind: kind,
            displayName: name,
            installedVersion: InstalledVersion(installed),
            availableVersion: AvailableVersion(current),
            versionScheme: RuntimeCatalog.versionScheme(for: name),
            signals: signals,
            ownership: ownership,
            notes: notes,
            details: details
        ))
    }

    /// The highest comparable version, or the last one listed.
    static func newest(_ versions: [String]) -> String {
        versions.reduce(versions[versions.count - 1]) { best, candidate in
            VersionComparator.compare(best, candidate) == .orderedAscending ? candidate : best
        }
    }
}
