import Foundation

/// Parsers for mise's JSON output.
///
/// `mise outdated --json` (mise 2026.x):
/// ```json
/// {"node": {"name": "node", "requested": "24", "current": "24.19.0", "bump": null,
///           "latest": "24.21.0", "source": {"type": "mise.toml", "path": "/…/config.toml"}}}
/// ```
/// Older releases emit only `requested`, `current`, and `latest`. Without
/// `--bump`, `latest` is the newest version matching `requested`, so the
/// configuration does not change.
///
/// `mise ls --json`:
/// ```json
/// {"node": [{"version": "24.19.0", "requested_version": "24", "install_path": "/…",
///            "source": {"type": "mise.toml", "path": "/…"}, "installed": true, "active": true}]}
/// ```
enum MiseParsers {
    struct Context {
        var homeDirectory: String
        var directories: MiseProvider.Directories
        var miseLink: OwnershipLink
        var fileSystem: any FileSystem
        var command: String?
    }

    // MARK: mise outdated --json

    static func parseOutdated(_ data: Data, context: Context) throws -> ProviderListing<UpdateCandidate> {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document = text.isEmpty ? .object([:]) : JSONValue.parse(Data(text.utf8)) else {
            throw MacUpError.parseFailed("mise's outdated list was not valid JSON.", command: context.command)
        }
        guard let tools = document.objectValue else {
            throw MacUpError.parseFailed("mise's outdated list was not a JSON object.", command: context.command)
        }

        var listing = ProviderListing<UpdateCandidate>()
        for (tool, entry) in tools.sorted(by: { $0.key < $1.key }) {
            let id: PackageID
            do {
                id = try PackageID(.mise, tool)
            } catch let error as PackageID.ValidationError {
                listing.findings.append(ProviderSupport.skippedName(tool, reason: error, provider: .mise))
                continue
            }
            guard entry.objectValue != nil else {
                listing.findings.append(ProviderSupport.skippedEntry(tool, provider: .mise, reason: "The entry is not an object."))
                continue
            }
            let requested = entry["requested"]?.stringValue
            guard let current = entry["current"]?.stringValue, !current.isEmpty else {
                listing.findings.append(DiagnosticFinding(
                    id: "mise.notInstalled",
                    severity: .info,
                    provider: .mise,
                    title: "\(tool) is requested but not installed",
                    detail: requested.map { "Requested version: \($0)." }
                ))
                continue
            }
            guard let latest = entry["latest"]?.stringValue, !latest.isEmpty else {
                listing.findings.append(ProviderSupport.skippedEntry(tool, provider: .mise, reason: "mise did not report a latest version."))
                continue
            }
            if latest == current { continue }
            if VersionComparator.compare(current, latest) == .orderedDescending {
                listing.findings.append(ProviderSupport.newerThanOffered(id, installed: current, offered: latest))
                continue
            }

            let sourcePath = entry["source"]?["path"]?.stringValue
            let sourceType = entry["source"]?["type"]?.stringValue
            let scope = MiseProvider.scope(of: sourcePath, type: sourceType, homeDirectory: context.homeDirectory, directories: context.directories)

            var signals: Set<RiskSignal> = []
            var notes: [String] = []
            var details: [String: String] = ["configScope": scope.rawValue]
            details["requested"] = requested
            details["configPath"] = sourcePath
            details["configType"] = sourceType

            if RuntimeCatalog.isRuntime(tool) { signals.insert(.runtimeOrToolchain) }
            if let requested, requested == current {
                signals.insert(.mayRewriteConfiguration)
                notes.append("Pinned to exactly \(current); reaching \(latest) would mean editing the configuration, which MacUp never does automatically.")
            } else if let requested {
                notes.append("Stays within the requested version \"\(requested)\"; the configuration file is not changed.")
            }
            switch scope {
            case .project:
                notes.append("Requested by project configuration \(sourcePath ?? ""). MacUp treats project-local updates as informational.")
            case .home:
                notes.append("Requested by \(sourcePath ?? "a file") in your home directory.")
            case .unknown:
                notes.append("MacUp could not tell which configuration file requests this tool.")
            case .global, .system:
                break
            }
            if let sourcePath {
                let lockfile = (sourcePath as NSString).deletingLastPathComponent + "/mise.lock"
                if context.fileSystem.fileExists(atPath: lockfile) {
                    signals.insert(.mayRewriteConfiguration)
                    notes.append("The lockfile \(lockfile) may be updated.")
                    details["lockfile"] = lockfile
                }
            }
            if ["node", "nodejs"].contains(RuntimeCatalog.baseName(tool)) {
                signals.insert(.mayAffectDependents)
                notes.append("Global npm packages are installed per Node version; packages installed under \(current) are not available under a new version until reinstalled.")
            }

            var links = [context.miseLink]
            if let sourcePath { links.append(OwnershipLink(label: "\(scope.rawValue) config", path: sourcePath)) }
            listing.elements.append(UpdateCandidate(
                id: id,
                kind: .tool,
                displayName: tool,
                installedVersion: InstalledVersion(current),
                availableVersion: AvailableVersion(latest),
                versionScheme: RuntimeCatalog.versionScheme(for: tool),
                signals: signals,
                ownership: OwnershipChain(links),
                notes: notes,
                details: details
            ))
        }
        return listing
    }

    // MARK: mise ls --json

    static func parseInventory(_ data: Data, context: Context) throws -> ProviderListing<ManagedItem> {
        guard let document = JSONValue.parse(data) else {
            throw MacUpError.parseFailed("mise's tool list was not valid JSON.", command: context.command)
        }
        guard let tools = document.objectValue else {
            throw MacUpError.parseFailed("mise's tool list was not a JSON object.", command: context.command)
        }

        var listing = ProviderListing<ManagedItem>()
        for (tool, value) in tools.sorted(by: { $0.key < $1.key }) {
            let id: PackageID
            do {
                id = try PackageID(.mise, tool)
            } catch let error as PackageID.ValidationError {
                listing.findings.append(ProviderSupport.skippedName(tool, reason: error, provider: .mise))
                continue
            }
            guard let entries = value.arrayValue else {
                listing.findings.append(ProviderSupport.skippedEntry(tool, provider: .mise, reason: "Expected a list of versions."))
                continue
            }
            let installed = entries.filter { $0["installed"]?.boolValue == true }.compactMap { $0["version"]?.stringValue }
            let active = entries.first { $0["active"]?.boolValue == true }
            var details: [String: String] = [:]
            if let active {
                let path = active["source"]?["path"]?.stringValue
                let type = active["source"]?["type"]?.stringValue
                details["requested"] = active["requested_version"]?.stringValue
                details["configPath"] = path
                details["configScope"] = MiseProvider.scope(of: path, type: type, homeDirectory: context.homeDirectory, directories: context.directories).rawValue
                if active["installed"]?.boolValue == false { details["activeVersionMissing"] = "true" }
            }
            let inactive = entries
                .filter { $0["active"]?.boolValue != true && $0["installed"]?.boolValue == true }
                .compactMap { $0["version"]?.stringValue }
            if !inactive.isEmpty { details["inactiveVersions"] = inactive.joined(separator: ", ") }

            listing.elements.append(ManagedItem(
                id: id,
                kind: .tool,
                displayName: tool,
                installedVersions: installed.map { InstalledVersion($0) },
                activeVersion: active?["version"]?.stringValue.map { InstalledVersion($0) },
                ownership: OwnershipChain([context.miseLink]),
                details: details
            ))
        }
        return listing
    }
}
