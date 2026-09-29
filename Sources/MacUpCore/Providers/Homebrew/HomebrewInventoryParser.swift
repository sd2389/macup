import Foundation

/// Parses `brew info --json=v2 --installed` into managed items.
///
/// Only a few documented fields are used: `full_name`, `installed[].version`,
/// `installed[].installed_on_request`, `linked_keg`, `pinned`, `tap`, `desc`,
/// `deprecated`, `disabled`, `homepage`, `bottle.stable.files[].cellar` for formulae; `token`, `name`,
/// `installed`, `pinned`, `auto_updates`, `artifacts`, `homepage` for casks. Everything else is ignored.
enum HomebrewInventoryParser {
    static func parse(_ data: Data, ownership: OwnershipChain?, command: String? = nil) throws -> ProviderListing<ManagedItem> {
        guard let document = JSONValue.parse(data) else {
            throw MacUpError.parseFailed("Homebrew's installed-package list was not valid JSON.", command: command)
        }
        guard let formulae = document["formulae"]?.arrayValue, let casks = document["casks"]?.arrayValue else {
            throw MacUpError.parseFailed(
                "Homebrew's installed-package list did not have the expected \"formulae\" and \"casks\" arrays.",
                command: command
            )
        }

        var listing = ProviderListing<ManagedItem>()
        for entry in formulae {
            guard let name = entry["full_name"]?.stringValue ?? entry["name"]?.stringValue else {
                listing.findings.append(ProviderSupport.skippedEntry("(unnamed formula)", provider: .homebrew, reason: "The entry has no name."))
                continue
            }
            guard let id = packageID(.brew, name, into: &listing) else { continue }
            let installed = entry["installed"]?.arrayValue ?? []
            let versions = installed.compactMap { $0["version"]?.stringValue }.map { InstalledVersion($0) }
            var details: [String: String] = [:]
            details["tap"] = entry["tap"]?.stringValue
            details["description"] = entry["desc"]?.stringValue
            details["homepage"] = entry["homepage"]?.stringValue
            // Any version installed on request makes the formula one the user
            // asked for. Reading only the last entry would take the word of a
            // version whose install never finished.
            if installed.contains(where: { $0["installed_on_request"]?.boolValue == true }) {
                details["installedOnRequest"] = "true"
            } else if let onRequest = installed.last?["installed_on_request"]?.boolValue {
                details["installedOnRequest"] = String(onRequest)
            }
            if entry["keg_only"]?.boolValue == true { details["kegOnly"] = "true" }
            // Where the current version's ready-made builds expect to live,
            // one line each. Empty when Homebrew has none, so it would build.
            if let bottle = entry["bottle"]?.objectValue {
                let files = bottle["stable"]?["files"]?.objectValue ?? [:]
                let cellars = Set(files.values.compactMap { $0["cellar"]?.stringValue })
                details["bottleCellars"] = cellars.sorted().joined(separator: "\n")
            }
            if entry["deprecated"]?.boolValue == true { details["deprecated"] = "true" }
            if entry["disabled"]?.boolValue == true { details["disabled"] = "true" }
            listing.elements.append(ManagedItem(
                id: id,
                kind: .formula,
                displayName: name,
                installedVersions: versions,
                activeVersion: entry["linked_keg"]?.stringValue.map { InstalledVersion($0) },
                pinnedByProvider: entry["pinned"]?.boolValue ?? false,
                ownership: ownership,
                details: details
            ))
        }

        for entry in casks {
            guard let token = entry["token"]?.stringValue else {
                listing.findings.append(ProviderSupport.skippedEntry("(unnamed cask)", provider: .homebrew, reason: "The entry has no token."))
                continue
            }
            guard let id = packageID(.brewCask, token, into: &listing) else { continue }
            let displayName = entry["name"]?.arrayValue?.first?.stringValue ?? token
            let installed = entry["installed"]?.stringValue
            var details: [String: String] = [:]
            details["tap"] = entry["tap"]?.stringValue
            details["description"] = entry["desc"]?.stringValue
            details["homepage"] = entry["homepage"]?.stringValue
            if entry["auto_updates"]?.boolValue == true { details["autoUpdates"] = "true" }
            if usesInstallerPackage(entry["artifacts"]) { details["usesInstallerPackage"] = "true" }
            listing.elements.append(ManagedItem(
                id: id,
                kind: .cask,
                displayName: displayName,
                installedVersions: installed.map { [InstalledVersion($0)] } ?? [],
                activeVersion: installed.map { InstalledVersion($0) },
                pinnedByProvider: entry["pinned"]?.boolValue ?? false,
                ownership: ownership,
                details: details
            ))
        }
        return listing
    }

    private static func packageID(_ namespace: PackageNamespace, _ name: String, into listing: inout ProviderListing<ManagedItem>) -> PackageID? {
        do {
            return try PackageID(namespace, name)
        } catch let error as PackageID.ValidationError {
            listing.findings.append(ProviderSupport.skippedName(name, reason: error, provider: .homebrew))
        } catch {}
        return nil
    }

    /// Casks with `pkg` or `installer` artifacts run a macOS installer package.
    private static func usesInstallerPackage(_ artifacts: JSONValue?) -> Bool {
        guard let artifacts = artifacts?.arrayValue else { return false }
        return artifacts.contains { artifact in
            artifact["pkg"] != nil || artifact["installer"] != nil
        }
    }
}
