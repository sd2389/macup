import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Doctor: configuration")
struct ConfigurationCheckTests {
    private let check = ConfigurationCheck()

    @Test("A validator error becomes an error that says automatic updates stay off")
    func validatorErrorIsAnError() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.configurationIssues = [ConfigurationIssue(
            .error,
            "providers.npm.enabeld",
            "Unknown key 'enabeld'. Allowed keys: enabled, executablePath, policy."
        )]

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["configuration.invalid"])
        #expect(findings[0].severity == .error)
        #expect(findings[0].title.contains("providers.npm.enabeld"))
        #expect(findings[0].recommendation?.contains("keeps automatic updates") == true)
    }

    @Test("A validator warning stays a warning and says the rest of the file is in use")
    func validatorWarningIsAWarning() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.configurationIssues = [ConfigurationIssue(
            .warning,
            "privacy.telemetry",
            "MacUp has no telemetry; this setting has no effect and nothing is sent."
        )]

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["configuration.questionable"])
        #expect(findings[0].severity == .warning)
        #expect(findings[0].recommendation?.contains("in use as written") == true)
    }

    @Test("A whole-file problem is reported against the file's path, not an empty location")
    func fileLevelIssueNamesTheFile() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.configurationIssues = [ConfigurationIssue(.error, "", "The configuration file could not be read.")]

        let findings = await check.run(scenario.input)
        #expect(findings[0].title.contains("~/.config/macup/config.json"))
    }

    @Test("A configuration read from an older schema is reported without changing the file")
    func migratedConfigurationIsReported() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.migratedFromSchemaVersion = 0

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["configuration.readFromOlderSchema"])
        #expect(findings[0].severity == .info)
        #expect(findings[0].detail?.contains("did not change the file") == true)
    }

    @Test("A valid configuration produces nothing")
    func validConfigurationIsSilent() async {
        let scenario = DoctorDiagnosticScenario()
        #expect(await check.run(scenario.input).isEmpty)
    }
}

@Suite("Doctor: stale item policies")
struct StaleItemPolicyCheckTests {
    private let check = StaleItemPolicyCheck()

    @Test("A policy naming software no provider has installed is reported as information")
    func stalePolicyIsReported() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.configuration.items = [
            "brew:postgresql": MacUpConfiguration.ItemSettings(policy: .ignore),
            "brew:git": MacUpConfiguration.ItemSettings(policy: .auto),
        ]
        scenario.add(.available(.homebrew, executable: "/opt/homebrew/bin/brew", items: [.formula("git", version: "2.51.0")]))

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["configuration.staleItemPolicy"])
        #expect(findings[0].severity == .info)
        #expect(findings[0].title == "A policy names software that is not installed")
        #expect(findings[0].detail?.contains("brew:postgresql") == true)
        #expect(findings[0].detail?.contains("brew:git") == false)
        #expect(findings[0].recommendation?.contains("macup policy clear") == true)
    }

    @Test("A policy for a provider MacUp could not list is never called stale")
    func policyForUnlistedProviderIsSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.configuration.items = ["npm:@anthropic-ai/claude-code": MacUpConfiguration.ItemSettings(policy: .ask)]
        scenario.add(.available(.homebrew, executable: "/opt/homebrew/bin/brew", items: [.formula("git", version: "2.51.0")]))
        scenario.add(.notInstalled(.npm))

        #expect(await check.run(scenario.input).isEmpty)
    }

    @Test("Policies that all name installed software produce nothing")
    func currentPoliciesAreSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.configuration.items = ["brew:git": MacUpConfiguration.ItemSettings(policy: .ignore)]
        scenario.add(.available(.homebrew, executable: "/opt/homebrew/bin/brew", items: [.formula("git", version: "2.51.0")]))

        #expect(await check.run(scenario.input).isEmpty)
    }
}

@Suite("Doctor: MacUp's own directories")
struct StateDirectoryCheckTests {
    private let check = StateDirectoryCheck(userID: DoctorDiagnosticScenario.userID)

    /// A scenario whose configuration and state directories exist and are
    /// owner-only.
    private func withDirectories() -> DoctorDiagnosticScenario {
        var scenario = DoctorDiagnosticScenario()
        scenario.fileSystem.addDirectory(scenario.paths.configDirectory)
        scenario.fileSystem.addDirectory(scenario.paths.stateDirectory)
        scenario.fileSystem.addDirectory(scenario.paths.launchAgentsDirectory)
        return scenario
    }

    @Test("A configuration directory other users can write is an error")
    func groupWritableDirectoryIsAnError() async {
        var scenario = withDirectories()
        scenario.fileSystem.setOwnership(
            scenario.paths.configDirectory,
            FileOwnership(uid: DoctorDiagnosticScenario.userID, gid: 20, mode: 0o775)
        )

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["paths.directoryWritableByOthers"])
        #expect(findings[0].severity == .error)
        #expect(findings[0].title == "Another user can change MacUp's configuration")
        #expect(findings[0].recommendation?.contains("chmod go-w ~/.config/macup") == true)
    }

    @Test("A state directory left behind by root is an error that explains sudo")
    func rootOwnedDirectoryIsAnError() async {
        var scenario = withDirectories()
        scenario.fileSystem.setOwnership(
            scenario.paths.stateDirectory,
            FileOwnership(uid: 0, gid: 0, mode: 0o755)
        )

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["paths.directoryUnusable"])
        #expect(findings[0].severity == .error)
        #expect(findings[0].title.contains("history and saved check results"))
        #expect(findings[0].recommendation?.contains("`sudo`") == true)
    }

    @Test("A file where a directory belongs is an error")
    func fileInsteadOfDirectoryIsAnError() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.fileSystem.addFile(scenario.paths.stateDirectory, contents: "not a directory")

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["paths.directoryUnusable"])
        #expect(findings[0].detail?.contains("is not a directory") == true)
    }

    @Test("A directory the owner cannot use is an error")
    func unusablePermissionsAreAnError() async {
        var scenario = withDirectories()
        scenario.fileSystem.setOwnership(
            scenario.paths.configDirectory,
            FileOwnership(uid: DoctorDiagnosticScenario.userID, gid: 20, mode: 0o500)
        )

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["paths.directoryUnusable"])
        #expect(findings[0].recommendation?.contains("chmod u+rwx") == true)
    }

    @Test("A directory that does not exist yet is not a problem")
    func absentDirectoriesAreSilent() async {
        let scenario = DoctorDiagnosticScenario()
        #expect(await check.run(scenario.input).isEmpty)
    }

    @Test("Owner-only directories produce nothing")
    func privateDirectoriesAreSilent() async {
        #expect(await check.run(withDirectories().input).isEmpty)
    }
}

@Suite("Doctor: scheduled check")
struct ScheduleCheckTests {
    private let check = ScheduleCheck()

    private func status(
        enabled: Bool,
        installed: Bool,
        loaded: Bool? = true,
        matches: Bool? = true,
        executableExists: Bool = true
    ) -> ScheduleStatus {
        ScheduleStatus(
            enabledInConfiguration: enabled,
            schedule: "every day at 23:00",
            refreshesMetadata: true,
            label: "com.macup.check",
            agentPath: "/Users/example/Library/LaunchAgents/com.macup.check.plist",
            agentInstalled: installed,
            agentLoaded: installed ? loaded : nil,
            agentMatchesConfiguration: installed ? matches : nil,
            command: "/usr/local/bin/macup check --save-state",
            executablePath: "/usr/local/bin/macup",
            executableExists: executableExists,
            nextRun: Date(timeIntervalSince1970: 1_700_040_000),
            logPath: "/Users/example/.local/state/macup/scheduler.log",
            lastCheck: nil,
            warnings: []
        )
    }

    @Test("A schedule the configuration asks for with no agent installed is an error")
    func enabledWithoutAgentIsAnError() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.schedule = status(enabled: true, installed: false)

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["schedule.notInstalled"])
        #expect(findings[0].severity == .error)
        #expect(findings[0].detail?.contains("every day at 23:00") == true)
        #expect(findings[0].recommendation?.contains("macup schedule enable") == true)
    }

    @Test("An agent left installed while the configuration has scheduling off is a warning")
    func agentWithoutConfigurationIsAWarning() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.schedule = status(enabled: false, installed: true)

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["schedule.installedWhileDisabled"])
        #expect(findings[0].severity == .warning)
        #expect(findings[0].recommendation?.contains("macup schedule disable") == true)
    }

    @Test("An installed agent launchd has not loaded is a warning")
    func unloadedAgentIsAWarning() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.schedule = status(enabled: true, installed: true, loaded: false)

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["schedule.notLoaded"])
        #expect(findings[0].severity == .warning)
    }

    @Test("An agent that no longer matches the configuration is a warning")
    func mismatchedAgentIsAWarning() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.schedule = status(enabled: true, installed: true, matches: false)

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["schedule.doesNotMatchConfiguration"])
        #expect(findings[0].severity == .warning)
    }

    @Test("An agent pointing at a command that is gone is an error")
    func missingCommandIsAnError() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.schedule = status(enabled: true, installed: true, executableExists: false)

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["schedule.commandMissing"])
        #expect(findings[0].severity == .error)
        #expect(findings[0].detail?.contains("/usr/local/bin/macup") == true)
    }

    @Test("A launchd state MacUp could not read is reported as unknown, not as running")
    func unknownLaunchdStateIsInformation() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.schedule = status(enabled: true, installed: true, loaded: nil)

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["schedule.stateUnknown"])
        #expect(findings[0].severity == .info)
    }

    @Test("Scheduling off with nothing installed produces nothing")
    func schedulingOffIsSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.schedule = status(enabled: false, installed: false)

        #expect(await check.run(scenario.input).isEmpty)
    }

    @Test("A loaded agent matching the configuration produces nothing")
    func activeScheduleIsSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.schedule = status(enabled: true, installed: true)

        #expect(await check.run(scenario.input).isEmpty)
    }

    @Test("Nothing is said when scheduling was never read")
    func unreadScheduleIsSilent() async {
        let scenario = DoctorDiagnosticScenario()
        #expect(await check.run(scenario.input).isEmpty)
    }
}
