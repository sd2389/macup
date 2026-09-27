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

    private var environment: [String: String]?
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

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
