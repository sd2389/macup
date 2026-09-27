import Foundation
import MacUpCore
import Observation

/// Everything the windows and the menu bar show. One instance per app.
///
/// All engine work goes through MacUpCore; this type only schedules it and
/// holds the latest results.
@MainActor
@Observable
final class AppModel {
    enum Section: Hashable {
        case dashboard, updates, doctor, history
    }

    var section: Section? = .dashboard
    private(set) var report: CheckReport?
    private(set) var configuration: LoadedConfiguration?
    private(set) var isChecking = false
    private(set) var shell: String?
    /// Why the login-shell environment could not be read, if it could not.
    private(set) var environmentProblem: String?

    /// What is actually scheduled, as opposed to what the configuration asks
    /// for. Read from launchd and the installed agent.
    private(set) var scheduleStatus: ScheduleStatus?
    private(set) var isChangingSchedule = false
    /// Why the last scheduling change did not happen, if it did not.
    private(set) var scheduleProblem: String?

    private var environment: [String: String]?
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// macOS authentication. A stored property so a future test target can
    /// replace it; nothing here ever sees a fingerprint, a face, or a password.
    private let authorizer: any BiometricAuthorizing = LocalAuthenticator()

    var updateCount: Int { report?.summary.updatesAvailable ?? 0 }

    /// The glanceable summary: never "up to date" unless the check is complete.
    var status: CheckStatus {
        CheckStatus(report: report, isChecking: isChecking, environmentProblem: environmentProblem)
    }

    /// Errors and warnings worth a look in Doctor.
    var attentionCount: Int {
        let providers = report?.providers ?? []
        let problems = providers.reduce(0) { total, provider in
            total + provider.errors.count + provider.findings.filter { $0.severity != .info }.count
        }
        return problems + (environmentProblem == nil ? 0 : 1) + (configuration?.hasErrors == true ? 1 : 0)
    }

    /// Runs a read-only check. Safe to call repeatedly; overlapping calls are ignored.
    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let environment = await loadEnvironment()
        let configuration = loadConfiguration()
        report = await CheckEngine.standard().run(
            configuration: configuration,
            environment: CheckEnvironment(
                runner: ProcessCommandRunner(),
                fileSystem: LocalFileSystem(),
                processEnvironment: environment,
                homeDirectory: home,
                system: .current()
            )
        )
    }

    // MARK: - Approval

    var securitySettings: MacUpConfiguration.SecuritySettings {
        configuration?.configuration.security ?? MacUpConfiguration.SecuritySettings()
    }

    /// What this Mac can ask for. Reading it shows no prompt.
    var biometricCapability: BiometricCapability {
        ApprovalGate(settings: securitySettings, authorizer: authorizer).capability
    }

    /// Whether MacUp could get approval at all with the given settings. When it
    /// could not, requiring approval would stop MacUp changing anything.
    func canAskForApproval(with settings: MacUpConfiguration.SecuritySettings) -> Bool {
        let capability = ApprovalGate(settings: settings, authorizer: authorizer).capability
        return capability.isAvailable || (settings.allowPasswordFallback && capability.hasFallback)
    }

    private(set) var securityProblem: String?

    /// Turns the approval requirement on or off. Changing it is itself a
    /// change, so it goes through the gate that is in force now.
    func applySecurity(_ settings: MacUpConfiguration.SecuritySettings) async {
        guard !isChangingSchedule else { return }
        isChangingSchedule = true
        defer { isChangingSchedule = false }
        securityProblem = nil

        let loaded = loadConfiguration()
        guard !loaded.hasErrors else {
            securityProblem = "MacUp will not change a configuration it cannot read. Fix the errors above first."
            return
        }
        let approval = await ApprovalGate(settings: loaded.configuration.security, authorizer: authorizer)
            .approve("change when MacUp asks for your approval")
        guard approval.allowsChange else {
            securityProblem = approval.explanation
            return
        }
        guard !settings.requireApproval || canAskForApproval(with: settings) else {
            securityProblem = "This Mac cannot ask you to confirm right now, so requiring approval would stop MacUp changing anything."
            return
        }
        guard let paths = try? resolvedPaths() else {
            securityProblem = "MacUp could not resolve where its files live, so it changed nothing."
            return
        }
        var configuration = loaded.configuration
        configuration.security = settings
        do {
            try ConfigurationStore(paths: paths).save(configuration)
            self.configuration = loadConfiguration()
        } catch let error as MacUpError {
            securityProblem = error.message
        } catch {
            securityProblem = "The setting could not be saved."
        }
    }

    // MARK: - Scheduling

    var scheduleSettings: MacUpConfiguration.ScheduleSettings {
        configuration?.configuration.schedule ?? MacUpConfiguration.ScheduleSettings()
    }

    /// Asks launchd and the file system what is scheduled. Changes nothing.
    func refreshScheduleStatus() async {
        let loaded = configuration ?? loadConfiguration()
        guard let paths = try? resolvedPaths(), let executable = scheduledExecutable() else {
            scheduleStatus = nil
            return
        }
        scheduleStatus = await scheduler(paths: paths, executable: executable).status(loaded.configuration.schedule)
    }

    /// Installs or removes the scheduled check and records it in the
    /// configuration. The same rules as the CLI: MacUp will not write a
    /// configuration it could not read, and will not schedule a command it
    /// cannot name.
    func applySchedule(_ settings: MacUpConfiguration.ScheduleSettings) async {
        guard !isChangingSchedule else { return }
        isChangingSchedule = true
        defer { isChangingSchedule = false }
        scheduleProblem = nil

        let loaded = loadConfiguration()
        guard !loaded.hasErrors else {
            scheduleProblem = "MacUp will not change a configuration it cannot read. Fix the errors above first."
            return
        }
        guard let paths = try? resolvedPaths() else {
            scheduleProblem = "MacUp could not resolve where its files live, so it changed nothing."
            return
        }
        guard let executable = scheduledExecutable() else {
            scheduleProblem = "MacUp could not find the macup command to schedule. Install the command-line tool, then try again."
            return
        }

        let approval = await ApprovalGate(settings: loaded.configuration.security, authorizer: authorizer)
            .approve("change MacUp's scheduled check")
        guard approval.allowsChange else {
            scheduleProblem = approval.explanation
            return
        }

        let scheduler = scheduler(paths: paths, executable: executable)
        do {
            if settings.enabled {
                _ = try await scheduler.install(settings)
            } else {
                _ = try await scheduler.remove()
            }
            var configuration = loaded.configuration
            configuration.schedule = settings
            try ConfigurationStore(paths: paths).save(configuration)
            self.configuration = loadConfiguration()
        } catch let error as MacUpError {
            scheduleProblem = error.message
        } catch {
            scheduleProblem = "The schedule could not be changed."
        }
        await refreshScheduleStatus()
    }

    /// The `macup` command a scheduled check runs. The copy inside the app
    /// bundle comes first: it is always present and always the same version as
    /// the app, so a schedule cannot end up running an older CLI. Otherwise
    /// MacUp looks for an installed `macup` on the user's search path.
    func scheduledExecutable() -> String? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/macup").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        let path = environment?["PATH"] ?? ProcessInfo.processInfo.environment["PATH"]
        let search = ExecutableSearch(name: "macup", searchPath: SearchPath.parse(path))
        if case .found(let resolved) = ExecutableResolver(fileSystem: LocalFileSystem()).resolve(search) {
            return resolved.path
        }
        return nil
    }

    private func scheduler(paths: MacUpPaths, executable: String) -> Scheduler {
        Scheduler(
            paths: paths,
            executable: executable,
            fileSystem: LocalFileSystem(),
            runner: ProcessCommandRunner(),
            processEnvironment: environment ?? ProcessInfo.processInfo.environment
        )
    }

    private func resolvedPaths() throws -> MacUpPaths {
        try MacUpPaths.resolve(homeDirectory: home, environment: ProcessInfo.processInfo.environment)
    }

    /// Reads the configuration file. Reading never creates or changes it.
    @discardableResult
    func loadConfiguration() -> LoadedConfiguration {
        let paths: MacUpPaths
        var pathProblem: ConfigurationIssue?
        do {
            paths = try MacUpPaths.resolve(homeDirectory: home, environment: ProcessInfo.processInfo.environment)
        } catch {
            // Match the CLI's refusal visibly: say why the default location is in use.
            let message = (error as? MacUpError)?.message ?? "The configuration location could not be resolved."
            pathProblem = ConfigurationIssue(.error, "", message + " MacUp is using the default location instead.")
            paths = MacUpPaths.standard(homeDirectory: home)
        }
        var loaded = ConfigurationStore(paths: paths).load()
        if let pathProblem { loaded.issues.insert(pathProblem, at: 0) }
        configuration = loaded
        return loaded
    }

    /// The environment of the user's login shell, read once per launch. An
    /// app started from Finder does not inherit it, and without it MacUp would
    /// miss tools installed outside the standard locations. A failed read is
    /// retried on the next check rather than cached.
    private func loadEnvironment() async -> [String: String] {
        if let environment { return environment }
        let shell = LoginShellEnvironment.userLoginShell()
        self.shell = shell
        var result = ProcessInfo.processInfo.environment
        do {
            result = try await LoginShellEnvironment.capture(
                shell: shell,
                runner: ProcessCommandRunner(),
                homeDirectory: home,
                baseEnvironment: ProcessInfo.processInfo.environment
            )
            environmentProblem = nil
            environment = result
        } catch let error as MacUpError {
            environmentProblem = error.message
        } catch {
            environmentProblem = "MacUp could not read your shell's environment."
        }
        return result
    }
}
