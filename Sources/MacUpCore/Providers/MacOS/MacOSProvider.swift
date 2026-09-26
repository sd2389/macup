import Foundation

/// macOS software updates — detection only (CLAUDE.md §9).
///
/// MacUp lists updates with `softwareupdate --list --no-scan` (the result of
/// macOS's last scan) and scans only for `macup check --refresh`. It never
/// installs, downloads, restarts, or asks for a password; updates are shown
/// for review in System Settings. `softwareupdate` is always run from
/// `/usr/sbin`, never resolved through PATH.
public struct MacOSProvider: UpdateProvider {
    public let id = ProviderID.macos
    public let capabilities: Set<ProviderCapability> = [.detect, .outdated, .refreshMetadata]
    public var softwareUpdatePath: String

    public init(softwareUpdatePath: String = "/usr/sbin/softwareupdate") {
        self.softwareUpdatePath = softwareUpdatePath
    }

    public func detect(context: ProviderContext) async -> ProviderStatus {
        guard context.fileSystem.isExecutableFile(atPath: softwareUpdatePath) else {
            return ProviderStatus(
                provider: id,
                availability: .unavailable,
                error: MacUpError(.providerUnavailable, "\(softwareUpdatePath) was not found.")
            )
        }
        let executable = ResolvedExecutable(
            path: softwareUpdatePath,
            canonicalPath: context.fileSystem.canonicalPath(ofPath: softwareUpdatePath) ?? softwareUpdatePath,
            source: .standardLocation
        )
        var facts = [ProviderFact(key: "architecture", label: "Architecture", value: context.system.architecture)]
        if let build = context.system.buildVersion {
            facts.insert(ProviderFact(key: "build", label: "Build", value: build), at: 0)
        }
        return ProviderStatus(
            provider: id,
            availability: .available,
            installation: ProviderInstallation(executable: executable, version: context.system.productVersion, facts: facts)
        )
    }

    /// A refresh is a fresh scan, which ``outdated(context:)`` performs when
    /// `context.refreshMetadata` is set; there is no separate step.
    public func refreshMetadata(context: ProviderContext) async throws -> [DiagnosticFinding] { [] }

    public func inventory(context: ProviderContext) async throws -> ProviderListing<ManagedItem> {
        ProviderListing()
    }

    public func outdated(context: ProviderContext) async throws -> ProviderListing<UpdateCandidate> {
        let installation = try await requireInstallation(context)
        let arguments = context.refreshMetadata ? ["--list"] : ["--list", "--no-scan"]
        let result = try await ProviderSupport.run(
            installation.executable.path,
            arguments,
            policy: EnvironmentPolicy.base,
            searchPath: SearchPath.system,
            context: context,
            workingDirectory: "/",
            timeout: context.refreshMetadata ? .seconds(600) : .seconds(90)
        )
        guard result.succeeded else {
            throw MacUpError.commandFailed(result, "`softwareupdate --list` failed.")
        }
        let parsed = try SoftwareUpdateParser.parse(
            standardOutput: result.standardOutputText,
            standardError: result.standardErrorText
        )

        var listing = ProviderListing<UpdateCandidate>(findings: parsed.findings)
        for entry in parsed.entries {
            let id: PackageID
            do {
                id = try PackageID(.macos, entry.label)
            } catch let error as PackageID.ValidationError {
                listing.findings.append(ProviderSupport.skippedName(entry.label, reason: error, provider: .macos))
                continue
            }
            var signals: Set<RiskSignal> = []
            var notes = ["MacUp only reports macOS updates. Install them from System Settings → General → Software Update."]
            var details: [String: String] = ["title": entry.title]
            if entry.isOperatingSystemUpdate { signals.insert(.operatingSystemUpdate) }
            if entry.requiresRestart {
                signals.insert(.restartRequired)
                details["action"] = entry.action
            }
            if entry.isBeta { notes.append("This is a beta release.") }
            if entry.recommended == false { notes.append("Apple does not mark this update as recommended.") }
            if let recommended = entry.recommended { details["recommended"] = String(recommended) }
            if let size = entry.sizeKiB { details["sizeKiB"] = String(size) }
            for (key, value) in entry.otherFields { details["field." + key] = value }

            listing.elements.append(UpdateCandidate(
                id: id,
                kind: .systemUpdate,
                displayName: entry.title,
                installedVersion: entry.isOperatingSystemUpdate ? InstalledVersion(context.system.productVersion) : nil,
                availableVersion: AvailableVersion(entry.version),
                signals: signals,
                ownership: OwnershipChain([OwnershipLink(label: "Apple Software Update", path: installation.executable.path)]),
                notes: notes,
                details: details
            ))
        }
        return listing
    }
}
