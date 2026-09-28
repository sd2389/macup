import Darwin
import Foundation
import MacUpCore

/// Describes a pretend Mac for Doctor's diagnostic checks.
///
/// Checks read a ``DiagnosticInput`` and nothing else, so a scenario is just
/// that value assembled from synthetic pieces: provider reports as though a
/// check had already run, a configuration as though one had been loaded, and a
/// fake file system. Nothing here touches the real machine — no provider is
/// run, and the real `~/.config/macup` is never read.
public struct DoctorDiagnosticScenario: Sendable {
    /// The user every synthetic directory belongs to, matching
    /// ``FakeFileSystem/defaultOwnership``.
    public static let userID = getuid()
    public static let home = "/Users/example"

    public var fileSystem = FakeFileSystem()
    public var runner = FakeCommandRunner()
    public var providers: [ProviderReport] = []
    public var configuration = MacUpConfiguration.defaults
    public var configurationSource = LoadedConfiguration.Source.file
    public var configurationIssues: [ConfigurationIssue] = []
    public var migratedFromSchemaVersion: Int?
    public var environment: [String: String] = [
        "HOME": DoctorDiagnosticScenario.home,
        "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
    ]
    public var system = SystemInfo(productVersion: "27.0", buildVersion: "26A428", architecture: "arm64")
    public var schedule: ScheduleStatus?
    public var updates: [UpdateCandidate] = []
    public var cancelled = false
    public var paths = MacUpPaths.standard(homeDirectory: DoctorDiagnosticScenario.home)

    public init() {}

    /// Sets `PATH` and, for convenience, creates each directory on it.
    @discardableResult
    public mutating func searchPath(_ directories: [String]) -> Self {
        environment["PATH"] = directories.joined(separator: ":")
        for directory in directories { fileSystem.addDirectory(directory) }
        return self
    }

    @discardableResult
    public mutating func add(_ report: ProviderReport) -> Self {
        providers.append(report)
        return self
    }

    public var loadedConfiguration: LoadedConfiguration {
        LoadedConfiguration(
            configuration: configuration,
            source: configurationSource,
            path: paths.configFile,
            issues: configurationIssues,
            migratedFromSchemaVersion: migratedFromSchemaVersion
        )
    }

    public var checkEnvironment: CheckEnvironment {
        CheckEnvironment(
            runner: runner,
            fileSystem: fileSystem,
            processEnvironment: environment,
            homeDirectory: Self.home,
            system: system,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    public var input: DiagnosticInput {
        DiagnosticInput(
            report: CheckReport(
                mode: .readOnly,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_001),
                cancelled: cancelled,
                configuration: ConfigurationSummary(loadedConfiguration),
                providers: providers,
                updates: updates,
                commands: []
            ),
            configuration: loadedConfiguration,
            environment: checkEnvironment,
            paths: paths,
            schedule: schedule
        )
    }
}

extension ProviderReport {
    /// A provider that was found and ran cleanly.
    public static func available(
        _ provider: ProviderID,
        executable: String,
        canonicalPath: String? = nil,
        version: String? = "1.0.0",
        facts: [ProviderFact] = [],
        items: [ManagedItem]? = [],
        updateCount: Int? = 0,
        unreadableUpdates: Int = 0,
        resultsIncomplete: Bool = false,
        findings: [DiagnosticFinding] = [],
        errors: [ProviderOperationError] = []
    ) -> ProviderReport {
        ProviderReport(
            provider: provider,
            displayName: provider.displayName,
            availability: .available,
            capabilities: [.detect, .inventory, .outdated],
            executable: ResolvedExecutable(
                path: executable,
                canonicalPath: canonicalPath ?? executable,
                source: .searchPath
            ),
            version: version,
            facts: facts,
            installedCount: items?.count,
            updateCount: updateCount,
            unreadableUpdates: unreadableUpdates,
            resultsIncomplete: resultsIncomplete,
            items: items,
            findings: findings,
            errors: errors
        )
    }

    /// A provider that is simply not installed.
    ///
    /// The check engine clears the detection error for an absent provider —
    /// not being installed is not a fault — so by default this carries none,
    /// exactly as a real report does. Pass `detail` for the case where
    /// something did record where it looked.
    public static func notInstalled(_ provider: ProviderID, detail: String? = nil) -> ProviderReport {
        ProviderReport(
            provider: provider,
            displayName: provider.displayName,
            availability: .unavailable,
            capabilities: [.detect],
            errors: detail.map {
                [ProviderOperationError(
                    operation: .detect,
                    error: MacUpError(.providerUnavailable, "\(provider.displayName) was not found.", detail: $0)
                )]
            } ?? []
        )
    }

    public static func failed(_ provider: ProviderID, _ error: MacUpError) -> ProviderReport {
        ProviderReport(
            provider: provider,
            displayName: provider.displayName,
            availability: .failed,
            capabilities: [.detect],
            errors: [ProviderOperationError(operation: .detect, error: error)]
        )
    }

    public static func disabled(_ provider: ProviderID) -> ProviderReport {
        ProviderReport(
            provider: provider,
            displayName: provider.displayName,
            availability: .disabled,
            capabilities: [.detect]
        )
    }
}

extension ManagedItem {
    /// A mise-managed runtime with one active version.
    public static func miseTool(
        _ name: String,
        active: String,
        configPath: String? = nil,
        installed: [String]? = nil
    ) -> ManagedItem {
        var details: [String: String] = [:]
        if let configPath { details["configPath"] = configPath }
        return ManagedItem(
            // A name a provider could not turn into a package ID never reaches
            // a ManagedItem, so a bad one here is a broken test, not input.
            id: try! PackageID(.mise, name),
            kind: .tool,
            displayName: name,
            installedVersions: (installed ?? [active]).map { InstalledVersion($0) },
            activeVersion: InstalledVersion(active),
            details: details
        )
    }

    public static func formula(_ name: String, version: String) -> ManagedItem {
        ManagedItem(
            id: try! PackageID(.brew, name),
            kind: .formula,
            displayName: name,
            installedVersions: [InstalledVersion(version)]
        )
    }
}

/// An architecture reader that answers from a table instead of reading files.
public final class FakeArchitectureReader: ExecutableArchitectureReading, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: ExecutableArchitectures] = [:]
    /// What to say about a path the test did not describe.
    public var fallback: ExecutableArchitectures

    public init(fallback: ExecutableArchitectures = .notMachO) {
        self.fallback = fallback
    }

    @discardableResult
    public func set(_ path: String, _ architectures: ExecutableArchitectures) -> Self {
        lock.withLock { answers[path] = architectures }
        return self
    }

    public func architectures(ofExecutableAt path: String) -> ExecutableArchitectures {
        lock.withLock { answers[path] } ?? fallback
    }
}
