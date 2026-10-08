import Foundation

/// What MacUp knows about its scheduled check, from the configuration, the
/// installed agent, and the last run. Reporting only: building it changes
/// nothing.
public struct ScheduleStatus: Sendable, Hashable, Codable {
    /// The last scheduled (or `--save-state`) check MacUp left behind.
    public struct LastCheck: Sendable, Hashable, Codable {
        public var path: String
        public var finishedAt: Date?
        public var updatesAvailable: Int?
        public var providersWithErrors: Int?
        /// Set when the file exists but could not be read as a check report.
        public var unreadable: Bool

        public init(
            path: String,
            finishedAt: Date? = nil,
            updatesAvailable: Int? = nil,
            providersWithErrors: Int? = nil,
            unreadable: Bool = false
        ) {
            self.path = path
            self.finishedAt = finishedAt
            self.updatesAvailable = updatesAvailable
            self.providersWithErrors = providersWithErrors
            self.unreadable = unreadable
        }
    }

    public var enabledInConfiguration: Bool
    /// For example "every day at 23:00".
    public var schedule: String
    public var refreshesMetadata: Bool
    /// Whether the scheduled run installs the items whose rule is Auto
    /// Update (ADR-023), rather than only reporting what it found. Part of
    /// the status because the surfaces a person audits the job with have to
    /// be able to say which of the two jobs is installed.
    public var installsAutoUpdates: Bool
    public var label: String
    public var agentPath: String
    public var agentInstalled: Bool
    /// Whether launchd has the job loaded. `nil` when MacUp could not ask.
    public var agentLoaded: Bool?
    /// Whether the installed agent still matches the configuration.
    /// `nil` when no agent is installed.
    public var agentMatchesConfiguration: Bool?
    /// The exact command launchd runs, for display.
    public var command: String
    public var executablePath: String
    public var executableExists: Bool
    public var nextRun: Date?
    public var logPath: String
    public var lastCheck: LastCheck?
    public var warnings: [String]

    /// Whether a scheduled run will actually happen.
    public var isActive: Bool { enabledInConfiguration && agentInstalled && agentLoaded != false }

    /// What the scheduled job is called in the surfaces that report it:
    /// "run" when it installs Auto Update items, "check" when it only looks.
    public var jobNoun: String { installsAutoUpdates ? "run" : "check" }
}

/// Installs, removes, and reports on the launchd user agent that runs
/// `macup check`.
///
/// Every `launchctl` invocation goes through ``CommandRunning`` as an
/// executable path and an argument array. The label and the agent path are
/// MacUp's own constants, never user text, so nothing here is assembled from
/// untrusted input.
public struct Scheduler: Sendable {
    /// launchctl's fixed location. Resolved by absolute path rather than
    /// through PATH, which a scheduled job should never depend on.
    public static let launchctlPath = "/bin/launchctl"

    public var paths: MacUpPaths
    /// Absolute path of the `macup` binary the agent should run.
    public var executable: String
    public var userID: uid_t
    public var fileSystem: any FileSystem
    public var runner: any CommandRunning
    public var processEnvironment: [String: String]

    public init(
        paths: MacUpPaths,
        executable: String,
        userID: uid_t = getuid(),
        fileSystem: any FileSystem = LocalFileSystem(),
        runner: any CommandRunning = ProcessCommandRunner(),
        processEnvironment: [String: String] = [:]
    ) {
        self.paths = paths
        self.executable = executable
        self.userID = userID
        self.fileSystem = fileSystem
        self.runner = runner
        self.processEnvironment = processEnvironment
    }

    public var agentPath: String { paths.launchAgentsDirectory + "/" + LaunchAgent.fileName }
    /// launchd's per-user GUI domain, for example `gui/501`.
    public var domainTarget: String { "gui/\(userID)" }
    public var serviceTarget: String { "\(domainTarget)/\(LaunchAgent.label)" }

    // MARK: - Installing

    /// Writes the agent and loads it. Replaces an existing agent so changing
    /// the time takes effect immediately rather than at the next login.
    @discardableResult
    public func install(_ settings: MacUpConfiguration.ScheduleSettings) async throws -> LaunchAgent {
        let agent = try LaunchAgent.scheduledCheck(settings: settings, executable: executable, paths: paths)
        guard fileSystem.isExecutableFile(atPath: executable) else {
            throw MacUpError(
                .configurationInvalid,
                "MacUp will not schedule \(TerminalText.sanitize(executable)) because it is not an executable file.",
                recoverySuggestion: "Install macup to a fixed location and run `macup schedule enable` again."
            )
        }
        try requireLaunchctl()

        // The agent writes its report and its log here; create the directory
        // before launchd needs it, not at 23:00.
        _ = try PrivateDirectory(paths.stateDirectory)
        let directory = try PrivateDirectory(paths.launchAgentsDirectory)
        try directory.write(try agent.propertyListData(), named: LaunchAgent.fileName)

        // Unload first: launchd keeps the old definition otherwise. A job that
        // was not loaded makes this fail, which is expected and not an error.
        _ = try? await launchctl(["bootout", serviceTarget], effect: .modifying)
        let result = try await launchctl(["bootstrap", domainTarget, agentPath], effect: .modifying)
        guard result.succeeded else {
            throw MacUpError(
                .commandFailed,
                "launchd refused to load the scheduled check: \(failureDetail(result)).",
                command: Redactor().redact(result.invocation.displayString),
                recoverySuggestion: "Run `macup schedule disable` to clean up, then try again."
            )
        }
        return agent
    }

    /// Unloads and deletes the agent. Returns whether anything was there.
    @discardableResult
    public func remove() async throws -> Bool {
        var removedSomething = false
        if fileSystem.isExecutableFile(atPath: Self.launchctlPath) {
            // A job that is not loaded is the desired end state, not a failure.
            if let result = try? await launchctl(["bootout", serviceTarget], effect: .modifying), result.succeeded {
                removedSomething = true
            }
        }
        if fileSystem.fileExists(atPath: agentPath) {
            let directory = try PrivateDirectory(paths.launchAgentsDirectory)
            if try directory.remove(named: LaunchAgent.fileName) { removedSomething = true }
        }
        return removedSomething
    }

    // MARK: - Reporting

    public func status(_ settings: MacUpConfiguration.ScheduleSettings, now: Date = Date()) async -> ScheduleStatus {
        var warnings: [String] = []
        let installedPropertyList = readInstalledPropertyList()
        let agentInstalled = fileSystem.fileExists(atPath: agentPath)

        let agent = try? LaunchAgent.scheduledCheck(settings: settings, executable: executable, paths: paths)
        if agent == nil {
            warnings.append("MacUp cannot describe this schedule; `macup schedule enable` will explain why.")
        }

        var loaded: Bool?
        if fileSystem.isExecutableFile(atPath: Self.launchctlPath) {
            loaded = (try? await launchctl(["print", serviceTarget], effect: .readOnly))?.succeeded
        } else {
            warnings.append("launchctl was not found at \(Self.launchctlPath), so MacUp could not ask launchd anything.")
        }

        var matches: Bool?
        if let installedPropertyList {
            matches = agent?.matches(installedPropertyList: installedPropertyList)
        }

        let executableExists = fileSystem.isExecutableFile(atPath: executable)
        if agentInstalled && !executableExists {
            warnings.append(
                "The scheduled command \(TerminalText.sanitize(executable)) no longer exists, so the check cannot run."
            )
        }
        if settings.enabled && !agentInstalled {
            warnings.append("The configuration turns scheduling on, but no agent is installed, so nothing runs.")
        }
        if !settings.enabled && agentInstalled {
            warnings.append("An agent is installed while the configuration has scheduling off.")
        }
        if agentInstalled && matches == false {
            warnings.append("The installed agent does not match the configuration; re-run `macup schedule enable`.")
        }
        if agentInstalled && loaded == false {
            warnings.append("launchd does not have the agent loaded, so it will not run until the next login.")
        }

        return ScheduleStatus(
            enabledInConfiguration: settings.enabled,
            schedule: settings.summary,
            refreshesMetadata: settings.refresh,
            installsAutoUpdates: settings.installsAutoUpdates,
            label: LaunchAgent.label,
            agentPath: agentPath,
            agentInstalled: agentInstalled,
            agentLoaded: loaded,
            agentMatchesConfiguration: matches,
            command: agent?.invocation.displayString
                ?? CommandInvocation(executable: executable, arguments: ["check", "--save-state"]).displayString,
            executablePath: executable,
            executableExists: executableExists,
            nextRun: agent?.nextRun(after: now),
            logPath: paths.schedulerLogFile,
            lastCheck: readLastCheck(),
            warnings: warnings
        )
    }

    /// Reads the report the last saved check left behind. Never fails: an
    /// unreadable file is reported as unreadable rather than guessed at.
    func readLastCheck() -> ScheduleStatus.LastCheck? {
        guard let data = fileSystem.contents(atPath: paths.lastCheckFile, maximumBytes: 8 * 1024 * 1024) else {
            return nil
        }
        struct StoredReport: Decodable {
            struct Summary: Decodable {
                var updatesAvailable: Int?
                var providersWithErrors: Int?
            }
            var finishedAt: Date?
            var summary: Summary?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let report = try? decoder.decode(StoredReport.self, from: data) else {
            return ScheduleStatus.LastCheck(path: paths.lastCheckFile, unreadable: true)
        }
        return ScheduleStatus.LastCheck(
            path: paths.lastCheckFile,
            finishedAt: report.finishedAt,
            updatesAvailable: report.summary?.updatesAvailable,
            providersWithErrors: report.summary?.providersWithErrors
        )
    }

    func readInstalledPropertyList() -> [String: Any]? {
        guard let data = fileSystem.contents(atPath: agentPath, maximumBytes: 256 * 1024) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    // MARK: - launchctl

    private func requireLaunchctl() throws {
        guard fileSystem.isExecutableFile(atPath: Self.launchctlPath) else {
            throw MacUpError(
                .providerUnavailable,
                "launchctl was not found at \(Self.launchctlPath), so MacUp cannot schedule anything."
            )
        }
    }

    private func launchctl(_ arguments: [String], effect: CommandEffect) async throws -> CommandResult {
        let request = CommandRequest(
            executable: URL(fileURLWithPath: Self.launchctlPath),
            arguments: arguments,
            environment: EnvironmentPolicy.base.environment(from: processEnvironment, searchPath: SearchPath.system),
            timeout: .seconds(30),
            effect: effect
        )
        return try await runner.run(request)
    }

    private func failureDetail(_ result: CommandResult) -> String {
        let text = result.standardErrorText.isEmpty ? result.standardOutputText : result.standardErrorText
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)
        guard let line, !line.isEmpty else {
            return "exit status \(result.exitStatus.map(String.init) ?? "unknown")"
        }
        return TerminalText.sanitize(line)
    }
}
