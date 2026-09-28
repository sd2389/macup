import Foundation

/// What a diagnostic check gets to look at. Everything is already gathered,
/// so a check runs no commands of its own unless it asks the runner directly.
public struct DiagnosticInput: Sendable {
    /// The read-only check behind this run, including provider reports.
    public var report: CheckReport
    public var configuration: LoadedConfiguration
    public var environment: CheckEnvironment
    public var paths: MacUpPaths
    /// What is actually scheduled, when scheduling was read.
    public var schedule: ScheduleStatus?

    public init(
        report: CheckReport,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment,
        paths: MacUpPaths,
        schedule: ScheduleStatus? = nil
    ) {
        self.report = report
        self.configuration = configuration
        self.environment = environment
        self.paths = paths
        self.schedule = schedule
    }
}

/// One deterministic diagnostic. Checks explain; they never fix (CLAUDE.md §13).
public protocol DiagnosticCheck: Sendable {
    /// Stable identifier, for example `homebrew.multipleInstallations`.
    var id: String { get }
    /// What this check is looking for, in one line.
    var title: String { get }
    func run(_ input: DiagnosticInput) async -> [DiagnosticFinding]
}

/// The result of `macup doctor`: everything MacUp noticed about this Mac's
/// developer environment, with nothing changed.
///
/// Schema version 1.
public struct DoctorReport: Sendable, Hashable, Codable {
    public static let schemaVersion = 1

    public struct Summary: Sendable, Hashable, Codable {
        public var errors: Int
        public var warnings: Int
        public var notes: Int
        /// Checks that ran.
        public var checksRun: Int

        public init(errors: Int, warnings: Int, notes: Int, checksRun: Int) {
            self.errors = errors
            self.warnings = warnings
            self.notes = notes
            self.checksRun = checksRun
        }
    }

    public var schemaVersion: Int
    public var kind: String
    public var macupVersion: String
    public var startedAt: Date
    public var finishedAt: Date
    /// Findings, most severe first, then by identifier.
    public var findings: [DiagnosticFinding]
    public var providers: [ProviderReport]
    public var configuration: ConfigurationSummary
    public var summary: Summary
    public var cancelled: Bool

    public init(
        startedAt: Date,
        finishedAt: Date,
        findings: [DiagnosticFinding],
        providers: [ProviderReport],
        configuration: ConfigurationSummary,
        checksRun: Int,
        cancelled: Bool = false
    ) {
        self.schemaVersion = Self.schemaVersion
        self.kind = "doctor"
        self.macupVersion = MacUp.version
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.findings = findings
        self.providers = providers
        self.configuration = configuration
        self.cancelled = cancelled
        self.summary = Summary(
            errors: findings.filter { $0.severity == .error }.count,
            warnings: findings.filter { $0.severity == .warning }.count,
            notes: findings.filter { $0.severity == .info }.count,
            checksRun: checksRun
        )
    }

    /// True when nothing needs attention: no errors and no warnings.
    public var isHealthy: Bool { summary.errors == 0 && summary.warnings == 0 }
}

/// Runs MacUp's deterministic diagnostics.
public struct DoctorEngine: Sendable {
    public var providers: [any UpdateProvider]
    public var checks: [any DiagnosticCheck]

    public init(providers: [any UpdateProvider], checks: [any DiagnosticCheck]) {
        self.providers = providers
        self.checks = checks
    }

    public static func standard() -> DoctorEngine {
        DoctorEngine(
            providers: [HomebrewProvider(), NpmProvider(), MiseProvider(), MacOSProvider()],
            checks: []
        )
    }

    /// Checks the machine, then runs every diagnostic over the result.
    public func run(
        configuration: LoadedConfiguration,
        environment: CheckEnvironment,
        paths: MacUpPaths,
        schedule: ScheduleStatus? = nil
    ) async -> DoctorReport {
        let startedAt = environment.now()
        let report = await CheckEngine(providers: providers).run(
            configuration: configuration,
            options: CheckOptions(includeInventoryItems: true),
            environment: environment
        )
        let input = DiagnosticInput(
            report: report,
            configuration: configuration,
            environment: environment,
            paths: paths,
            schedule: schedule
        )
        var findings: [DiagnosticFinding] = []
        for check in checks {
            findings += await check.run(input)
        }
        findings += report.providers.flatMap(\.findings)
        return DoctorReport(
            startedAt: startedAt,
            finishedAt: environment.now(),
            findings: findings.sorted { $0.severity == $1.severity ? $0.id < $1.id : $0.severity > $1.severity },
            providers: report.providers,
            configuration: ConfigurationSummary(configuration),
            checksRun: checks.count,
            cancelled: report.cancelled
        )
    }
}
