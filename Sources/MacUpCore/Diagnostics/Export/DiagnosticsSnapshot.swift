import Foundation

/// What an exported diagnostics file is made from, exactly as MacUp found it.
///
/// Nothing here is redacted yet; ``DiagnosticsDocument`` does that. The two
/// are kept apart so that choosing whether to include package names renders
/// the same look at the Mac again rather than checking it a second time, and
/// so a preview and the file saved after it cannot come from two different
/// looks at the machine.
public struct DiagnosticsSnapshot: Sendable, Hashable {
    public var createdAt: Date
    public var system: SystemInfo
    /// Whose home directory becomes `~` in the file.
    public var homeDirectory: String
    /// The read-only check Doctor's findings were drawn from.
    public var check: CheckReport?
    public var doctor: DoctorReport?
    public var configuration: LoadedConfiguration
    /// The most recent entries, newest first.
    public var history: HistoryReading?
    /// Why the history could not be read, when it could not.
    public var historyProblem: String?

    public init(
        createdAt: Date,
        system: SystemInfo,
        homeDirectory: String,
        check: CheckReport?,
        doctor: DoctorReport?,
        configuration: LoadedConfiguration,
        history: HistoryReading?,
        historyProblem: String? = nil
    ) {
        self.createdAt = createdAt
        self.system = system
        self.homeDirectory = homeDirectory
        self.check = check
        self.doctor = doctor
        self.configuration = configuration
        self.history = history
        self.historyProblem = historyProblem
    }

    /// Whether gathering was interrupted, which leaves the findings partial.
    public var cancelled: Bool {
        check?.cancelled == true || doctor?.cancelled == true
    }
}

/// Gathers a ``DiagnosticsSnapshot``: one read-only check with Doctor over
/// it, the configuration the caller already loaded, and recent history.
///
/// Everything it does reads. It runs the same read-only check `macup check`
/// runs, through the same allowlist, changes nothing, and writes nothing —
/// not even the file; that is ``DiagnosticsFile``'s job, once somebody has
/// looked at what would be in it.
public struct DiagnosticsCollector: Sendable {
    public var doctorEngine: DoctorEngine

    public init(doctorEngine: DoctorEngine = .standard()) {
        self.doctorEngine = doctorEngine
    }

    public func collect(
        configuration: LoadedConfiguration,
        environment: CheckEnvironment,
        paths: MacUpPaths,
        schedule: ScheduleStatus? = nil
    ) async -> DiagnosticsSnapshot {
        let createdAt = environment.now()
        let (doctor, check) = await doctorEngine.diagnose(
            configuration: configuration,
            environment: environment,
            paths: paths,
            schedule: schedule
        )
        var history: HistoryReading?
        var historyProblem: String?
        do {
            history = try HistoryStore(paths: paths).read(limit: DiagnosticsDocument.historyLimit)
        } catch {
            let failure = MacUpError.wrapping(error, context: "Reading MacUp's history")
            historyProblem = [failure.message, failure.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
        }
        return DiagnosticsSnapshot(
            createdAt: createdAt,
            system: environment.system,
            homeDirectory: environment.homeDirectory,
            check: check,
            doctor: doctor,
            configuration: configuration,
            history: history,
            historyProblem: historyProblem
        )
    }
}
