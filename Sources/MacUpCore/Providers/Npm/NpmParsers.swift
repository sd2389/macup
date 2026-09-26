import Foundation

/// Parsers for npm's JSON output. npm prints JSON even for errors:
///
/// ```json
/// {"error": {"code": "ENOENT", "summary": "...", "detail": "..."}}
/// ```
///
/// and `npm outdated` exits 1 when updates exist, so the exit status alone
/// does not decide success.
enum NpmParsers {
    struct Context {
        var globalRoot: String?
        var ownership: OwnershipChain?
        var nodeManager: NodeManager = .unknown
        var command: String?
    }

    // MARK: Errors

    /// The error npm reported in JSON, if any.
    static func reportedError(in document: JSONValue, command: String?) -> MacUpError? {
        guard let error = document["error"]?.objectValue else { return nil }
        let code = error["code"]?.stringValue ?? "unknown"
        let summary = error["summary"]?.stringValue.map { Redactor().redact($0) }
        let detail = [summary, error["detail"]?.stringValue.map { Redactor().redact($0) }]
            .compactMap { $0 }
            .joined(separator: "\n")
        let message: String
        let recovery: String?
        switch code {
        case "EACCES", "EPERM":
            message = "npm was denied access to its global packages."
            recovery = "Check the ownership of npm's global directory; MacUp never changes permissions."
        case "ENOENT":
            message = "npm could not find a file or directory it needed."
            recovery = nil
        case "ENOTFOUND", "EAI_AGAIN", "ETIMEDOUT", "ECONNREFUSED", "ECONNRESET", "ENETUNREACH":
            message = "npm could not reach the package registry."
            recovery = "Check your network connection and npm registry settings."
        case "E401", "E403", "ENEEDAUTH":
            message = "The npm registry refused the request (authentication)."
            recovery = "Check your npm registry credentials."
        default:
            message = "npm reported an error (\(TerminalText.sanitize(code)))."
            recovery = nil
        }
        return MacUpError(
            .commandFailed,
            message,
            detail: detail.isEmpty ? nil : detail,
            command: command,
            recoverySuggestion: recovery
        )
    }

    // MARK: npm outdated -g --json

    /// Parses `npm outdated -g --json`.
    ///
    /// Exit statuses 0 and 1 are both normal; 1 means "updates exist".
    static func parseOutdated(_ result: CommandResult, context: Context) throws -> ProviderListing<UpdateCandidate> {
        let text = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let document: JSONValue
        if text.isEmpty && result.succeeded {
            document = .object([:])
        } else if let parsed = JSONValue.parse(Data(text.utf8)) {
            document = parsed
        } else if !result.succeeded {
            throw MacUpError.commandFailed(result, "`npm outdated` failed.")
        } else {
            throw MacUpError.parseFailed("npm's outdated list was not valid JSON.", command: context.command)
        }
        if let error = reportedError(in: document, command: context.command) { throw error }
        guard result.exitStatus == 0 || result.exitStatus == 1 else {
            throw MacUpError.commandFailed(result, "`npm outdated` exited unexpectedly.")
        }
        guard let entries = document.objectValue else {
            throw MacUpError.parseFailed("npm's outdated list was not a JSON object.", command: context.command)
        }

        var listing = ProviderListing<UpdateCandidate>()
        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
            let id: PackageID
            do {
                id = try PackageID(.npm, name)
            } catch let error as PackageID.ValidationError {
                listing.findings.append(ProviderSupport.skippedName(name, reason: error, provider: .npm))
                continue
            }
            guard entry.objectValue != nil else {
                listing.findings.append(ProviderSupport.skippedEntry(name, provider: .npm, reason: "The entry is not an object."))
                continue
            }
            guard let current = entry["current"]?.stringValue else {
                listing.findings.append(DiagnosticFinding(
                    id: "npm.missingPackage",
                    severity: .info,
                    provider: .npm,
                    title: "npm lists \(name) but it is not installed",
                    detail: "npm reports no installed version for this global package."
                ))
                continue
            }
            guard let latest = entry["latest"]?.stringValue else {
                listing.findings.append(ProviderSupport.skippedEntry(name, provider: .npm, reason: "npm did not report a latest version."))
                continue
            }
            let location = entry["location"]?.stringValue
            if let location, let root = context.globalRoot, !isInside(location, root) {
                listing.findings.append(DiagnosticFinding(
                    id: "npm.ambiguousOwnership",
                    severity: .warning,
                    provider: .npm,
                    title: "Skipped \(name): it is not inside npm's global directory",
                    detail: "Location \(location); global directory \(root).",
                    recommendation: "MacUp skips items whose ownership is ambiguous."
                ))
                continue
            }
            switch VersionComparator.compare(current, latest) {
            case .orderedDescending?:
                listing.findings.append(ProviderSupport.newerThanOffered(id, installed: current, offered: latest))
                continue
            case .orderedSame?:
                continue
            case .orderedAscending?, nil:
                if current == latest { continue }
            }

            var signals: Set<RiskSignal> = []
            var notes: [String] = []
            var details: [String: String] = [:]
            details["location"] = location
            details["wanted"] = entry["wanted"]?.stringValue
            if let wanted = entry["wanted"]?.stringValue, wanted != latest {
                notes.append("npm reports wanted \(wanted) and latest \(latest); global packages have no version range, so MacUp shows latest.")
            }
            if RuntimeCatalog.isPackageManager(name) {
                signals.insert(.packageManagerSelfUpdate)
            }
            if name == "npm" {
                let owner = context.nodeManager == .unknown
                    ? ""
                    : " This Node installation is managed by \(context.nodeManager.displayName); updating Node there may be the better choice."
                notes.append("Updating npm replaces the npm your shell and MacUp use.\(owner)")
            }
            listing.elements.append(UpdateCandidate(
                id: id,
                kind: .globalPackage,
                displayName: name,
                installedVersion: InstalledVersion(current),
                availableVersion: AvailableVersion(latest),
                signals: signals,
                ownership: context.ownership,
                notes: notes,
                details: details
            ))
        }
        return listing
    }

    // MARK: npm ls -g --json --depth=0

    /// Parses `npm ls -g --json --depth=0`. npm exits 1 when it finds problems
    /// (missing or invalid packages) but still prints the tree.
    static func parseInventory(_ result: CommandResult, context: Context) throws -> ProviderListing<ManagedItem> {
        guard let document = JSONValue.parse(result.standardOutput) else {
            if !result.succeeded { throw MacUpError.commandFailed(result, "`npm ls` failed.") }
            throw MacUpError.parseFailed("npm's package list was not valid JSON.", command: context.command)
        }
        if let error = reportedError(in: document, command: context.command) { throw error }
        guard document.objectValue != nil else {
            throw MacUpError.parseFailed("npm's package list was not a JSON object.", command: context.command)
        }

        var listing = ProviderListing<ManagedItem>()
        if let problems = document["problems"]?.arrayValue, !problems.isEmpty {
            listing.findings.append(DiagnosticFinding(
                id: "npm.globalTreeProblems",
                severity: .warning,
                provider: .npm,
                title: "npm reports problems with the global packages",
                detail: problems.compactMap(\.stringValue).prefix(5).map { Redactor().redact($0) }.joined(separator: "\n")
            ))
        } else if !result.succeeded {
            throw MacUpError.commandFailed(result, "`npm ls` failed.")
        }

        for (name, entry) in (document["dependencies"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            let id: PackageID
            do {
                id = try PackageID(.npm, name)
            } catch let error as PackageID.ValidationError {
                listing.findings.append(ProviderSupport.skippedName(name, reason: error, provider: .npm))
                continue
            }
            var details: [String: String] = [:]
            for flag in ["missing", "invalid", "extraneous"] where entry[flag]?.boolValue == true {
                details[flag] = "true"
            }
            let version = entry["version"]?.stringValue
            listing.elements.append(ManagedItem(
                id: id,
                kind: .globalPackage,
                displayName: name,
                installedVersions: version.map { [InstalledVersion($0)] } ?? [],
                activeVersion: version.map { InstalledVersion($0) },
                ownership: context.ownership,
                details: details
            ))
        }
        return listing
    }

    private static func isInside(_ path: String, _ directory: String) -> Bool {
        let path = (path as NSString).standardizingPath
        let directory = (directory as NSString).standardizingPath
        return path == directory || path.hasPrefix(directory + "/")
    }
}
