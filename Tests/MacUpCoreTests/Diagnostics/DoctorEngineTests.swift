import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Doctor engine")
struct DoctorEngineTests {
    /// A check that returns whatever the test handed it.
    private struct FixedCheck: DiagnosticCheck {
        let id: String
        let title = "A check the test controls"
        let findings: [DiagnosticFinding]

        func run(_ input: DiagnosticInput) async -> [DiagnosticFinding] { findings }
    }

    /// A provider that reports a finding while being detected, the way the
    /// real ones do, so the engine's de-duplication can be exercised.
    private struct StubProvider: UpdateProvider {
        let id: ProviderID
        let capabilities: Set<ProviderCapability> = [.detect, .outdated]
        var findings: [DiagnosticFinding] = []

        func detect(context: ProviderContext) async -> ProviderStatus {
            ProviderStatus(
                provider: id,
                availability: .available,
                installation: ProviderInstallation(
                    executable: ResolvedExecutable(path: "/usr/bin/true", canonicalPath: "/usr/bin/true", source: .searchPath),
                    version: "1.0.0"
                ),
                findings: findings
            )
        }

        func inventory(context: ProviderContext) async throws -> ProviderListing<ManagedItem> { ProviderListing() }
        func outdated(context: ProviderContext) async throws -> ProviderListing<UpdateCandidate> { ProviderListing() }
    }

    private func finding(
        _ id: String,
        _ severity: DiagnosticFinding.Severity,
        detail: String? = nil
    ) -> DiagnosticFinding {
        DiagnosticFinding(id: id, severity: severity, provider: nil, title: "Something about \(id)", detail: detail)
    }

    private func report(
        _ scenario: DoctorDiagnosticScenario,
        providers: [any UpdateProvider] = [],
        checks: [any DiagnosticCheck]
    ) async -> DoctorReport {
        await DoctorEngine(providers: providers, checks: checks).run(
            configuration: scenario.loadedConfiguration,
            environment: scenario.checkEnvironment,
            paths: scenario.paths,
            schedule: scenario.schedule
        )
    }

    @Test("Findings come back most severe first, then by identifier")
    func findingsAreSortedBySeverityThenIdentifier() async {
        let scenario = DoctorDiagnosticScenario()
        let result = await report(scenario, checks: [
            FixedCheck(id: "one", findings: [finding("z.note", .info), finding("a.problem", .error)]),
            FixedCheck(id: "two", findings: [finding("b.concern", .warning), finding("a.note", .info)]),
        ])

        #expect(result.findings.map(\.id) == ["a.problem", "b.concern", "a.note", "z.note"])
        #expect(result.summary.errors == 1)
        #expect(result.summary.warnings == 1)
        #expect(result.summary.notes == 2)
        #expect(result.summary.checksRun == 2)
        #expect(!result.isHealthy)
    }

    @Test("Findings with one identifier are ordered by their text, so two runs agree")
    func repeatedIdentifiersAreOrderedDeterministically() async {
        let scenario = DoctorDiagnosticScenario()
        let checks: [any DiagnosticCheck] = [FixedCheck(id: "one", findings: [
            finding("npm.unreadableEntry", .warning, detail: "second"),
            finding("npm.unreadableEntry", .warning, detail: "first"),
        ])]

        let result = await report(scenario, checks: checks)
        #expect(result.findings.compactMap(\.detail) == ["first", "second"])
    }

    @Test("The same finding from two checks is reported once")
    func identicalFindingsAreCollapsed() async {
        let scenario = DoctorDiagnosticScenario()
        let shared = finding("paths.directoryWritableByOthers", .error)
        let result = await report(scenario, checks: [
            FixedCheck(id: "one", findings: [shared]),
            FixedCheck(id: "two", findings: [shared]),
        ])

        #expect(result.findings == [shared])
        #expect(result.summary.errors == 1)
    }

    @Test("A finding a provider already reported is not repeated by a check")
    func providerFindingsAreCollapsed() async {
        let scenario = DoctorDiagnosticScenario()
        let shared = DiagnosticFinding(
            id: "homebrew.multipleInstallations",
            severity: .warning,
            provider: .homebrew,
            title: "More than one Homebrew installation was found"
        )
        let result = await report(
            scenario,
            providers: [StubProvider(id: .homebrew, findings: [shared])],
            checks: [FixedCheck(id: "one", findings: [shared])]
        )

        #expect(result.findings == [shared])
    }

    @Test("What a provider noticed during the check reaches the report on its own")
    func providerFindingsReachTheReport() async {
        let scenario = DoctorDiagnosticScenario()
        let observed = DiagnosticFinding(
            id: "npm.globalRootUnknown",
            severity: .warning,
            provider: .npm,
            title: "npm did not report its global package directory"
        )
        let result = await report(scenario, providers: [StubProvider(id: .npm, findings: [observed])], checks: [])

        #expect(result.findings == [observed])
        #expect(result.providers.map(\.provider) == [.npm])
        #expect(result.summary.checksRun == 0)
    }

    @Test("The report says which version and schema produced it")
    func reportIsVersioned() async {
        let scenario = DoctorDiagnosticScenario()
        let result = await report(scenario, checks: [])

        #expect(result.schemaVersion == DoctorReport.schemaVersion)
        #expect(result.kind == "doctor")
        #expect(result.macupVersion == MacUp.version)
        #expect(result.configuration.path == scenario.paths.configFile)
    }

    @Test("The standard engine runs every diagnostic MacUp ships, with stable identifiers")
    func standardChecksAreStable() {
        #expect(DoctorEngine.standard().checks.map(\.id) == [
            "provider.availability",
            "provider.results",
            "homebrew.installations",
            "homebrew.state",
            "provider.architecture",
            "environment.loginShell",
            "runtime.ownership",
            "npm.ownership",
            "configuration.file",
            "configuration.itemPolicies",
            "paths.directories",
            "schedule.agent",
        ])
        #expect(DoctorEngine.standard().providers.map(\.id) == [.homebrew, .npm, .mise, .macos])
    }

    @Test("Every diagnostic has a title a person can read")
    func everyCheckDescribesItself() {
        for check in DoctorEngine.standard().checks {
            #expect(!check.title.isEmpty)
            #expect(check.title.first?.isUppercase == true)
            #expect(!check.title.hasSuffix("."))
        }
    }
}

@Suite("Doctor: a machine with nothing wrong")
struct HealthyMachineDiagnosticsTests {
    /// A Mac where Homebrew, npm, mise, and macOS updates are all where MacUp
    /// expects them, the configuration is valid, and nothing is scheduled.
    static func scenario() -> DoctorDiagnosticScenario {
        var scenario = DoctorDiagnosticScenario()
        scenario.searchPath(["/opt/homebrew/bin", "/usr/bin", "/bin"])
        scenario.fileSystem.addExecutable("/opt/homebrew/bin/brew")
        scenario.fileSystem.addExecutable("/opt/homebrew/bin/npm")
        scenario.fileSystem.addExecutable("/opt/homebrew/bin/node")
        scenario.fileSystem.addExecutable("/opt/homebrew/bin/mise")
        scenario.fileSystem.addDirectory(scenario.paths.configDirectory)
        scenario.fileSystem.addDirectory(scenario.paths.stateDirectory)
        scenario.fileSystem.addDirectory(scenario.paths.launchAgentsDirectory)
        scenario.add(.available(
            .homebrew,
            executable: "/opt/homebrew/bin/brew",
            facts: [ProviderFact(key: "prefix", label: "Prefix", value: "/opt/homebrew")],
            items: [.formula("git", version: "2.51.0")],
            updateCount: 1
        ))
        scenario.add(.available(
            .npm,
            executable: "/opt/homebrew/bin/npm",
            facts: [
                ProviderFact(key: NpmProvider.FactKey.nodePath, label: "Node", value: "/opt/homebrew/bin/node"),
                ProviderFact(key: NpmProvider.FactKey.nodeVersion, label: "Node version", value: "v24.19.0"),
                ProviderFact(key: NpmProvider.FactKey.globalPrefix, label: "Global prefix", value: "/opt/homebrew"),
                ProviderFact(key: NpmProvider.FactKey.globalRoot, label: "Global packages", value: "/opt/homebrew/lib/node_modules"),
            ]
        ))
        scenario.add(.available(.mise, executable: "/opt/homebrew/bin/mise"))
        scenario.add(.available(.macos, executable: "/usr/sbin/softwareupdate", items: nil, updateCount: 0))
        return scenario
    }

    /// The shipping checks, with the two that reach outside the scenario
    /// replaced: the login shell answers with the environment MacUp ran with,
    /// and architectures come from a table instead of the disk.
    static func checks(architectures: FakeArchitectureReader = FakeArchitectureReader()) -> [any DiagnosticCheck] {
        DoctorEngine.standard().checks.map { check in
            if check is ShellEnvironmentCheck {
                return ShellEnvironmentCheck(read: { input in
                    ("/bin/zsh", input.environment.processEnvironment)
                })
            }
            if check is ExecutableArchitectureCheck {
                return ExecutableArchitectureCheck(reader: architectures)
            }
            return check
        }
    }

    static func runAll(
        _ input: DiagnosticInput,
        architectures: FakeArchitectureReader = FakeArchitectureReader()
    ) async -> [DiagnosticFinding] {
        var findings: [DiagnosticFinding] = []
        for check in checks(architectures: architectures) {
            findings += await check.run(input)
        }
        return findings
    }

    @Test("Nothing at all is reported about a machine with nothing wrong")
    func healthyMachineIsSilent() async {
        let findings = await Self.runAll(Self.scenario().input)
        #expect(findings.isEmpty, "unexpected findings: \(findings.map(\.id))")
    }

    @Test("A machine with providers missing has no errors and no warnings")
    func missingProvidersAreNotFaults() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.searchPath(["/usr/bin", "/bin"])
        scenario.add(.notInstalled(.homebrew))
        scenario.add(.notInstalled(.npm))
        scenario.add(.notInstalled(.mise))
        scenario.add(.available(.macos, executable: "/usr/sbin/softwareupdate", items: nil))

        let findings = await Self.runAll(scenario.input)
        #expect(findings.allSatisfy { $0.severity == .info })
        #expect(findings.filter { $0.id == "provider.notFound" }.count == 3)
    }

    @Test("Every finding carries a title, a detail, and something to do about it")
    func findingsAreActionable() async {
        var scenario = HealthyMachineDiagnosticsTests.scenario()
        // One thing wrong per area, so each check contributes.
        scenario.configurationIssues = [ConfigurationIssue(.error, "global.defaultPolicy", "Pin applies to individual items.")]
        scenario.configuration.items = ["brew:postgresql": MacUpConfiguration.ItemSettings(policy: .ignore)]
        scenario.fileSystem.setOwnership(
            scenario.paths.stateDirectory,
            FileOwnership(uid: DoctorDiagnosticScenario.userID, gid: 20, mode: 0o777)
        )
        scenario.providers[3] = .failed(.macos, MacUpError(.commandFailed, "softwareupdate could not be run."))

        let findings = await Self.runAll(scenario.input)
        #expect(!findings.isEmpty)
        for finding in findings {
            #expect(!finding.id.isEmpty)
            #expect(finding.id.contains("."), "identifier should be namespaced: \(finding.id)")
            #expect(!finding.title.isEmpty)
            #expect(finding.detail?.isEmpty == false, "\(finding.id) says nothing about what MacUp observed")
            #expect(finding.recommendation?.isEmpty == false, "\(finding.id) offers nothing to do")
        }
    }

    @Test("Diagnosing a machine runs nothing against it")
    func diagnosingRunsNoCommands() async {
        var scenario = HealthyMachineDiagnosticsTests.scenario()
        scenario.configurationIssues = [ConfigurationIssue(.error, "schedule.time", "Use 24-hour HH:mm.")]
        scenario.providers[2] = .failed(.mise, MacUpError(.commandFailed, "mise could not be run."))

        _ = await Self.runAll(scenario.input)
        #expect(scenario.runner.recordedRequests.isEmpty)
    }

    @Test("Reading the login shell is the only command Doctor issues, and it changes nothing")
    func theOnlyCommandIsTheLoginShell() async {
        let scenario = HealthyMachineDiagnosticsTests.scenario()
        // The fake runner refuses everything, so the check reports that it
        // could not read the shell — and no real shell is ever started.
        let findings = await ShellEnvironmentCheck().run(scenario.input)

        #expect(findings.map(\.id) == ["environment.loginShellUnreadable"])
        #expect(!scenario.runner.recordedRequests.isEmpty)
        #expect(scenario.runner.recordedRequests.allSatisfy { $0.effect == .readOnly })
    }
}

@Suite("Doctor: findings never carry a secret")
struct DiagnosticRedactionTests {
    @Test("Tokens in provider errors and configuration messages are redacted")
    func secretsInUntrustedTextAreRedacted() async {
        var scenario = HealthyMachineDiagnosticsTests.scenario()
        scenario.providers[2] = .failed(.mise, MacUpError(
            .commandFailed,
            "mise failed: GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123 was rejected",
            detail: "authorization: Bearer sk-abcdefghijklmnopqrstuvwxyz01"
        ))
        scenario.configurationIssues = [ConfigurationIssue(
            .error,
            "providers.npm.executablePath",
            "npm_config__authToken=npm_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa is not a path"
        )]

        let findings = await HealthyMachineDiagnosticsTests.runAll(scenario.input)
        #expect(!findings.isEmpty)
        for secret in ["ghp_abcdefghijklmnopqrstuvwxyz0123", "sk-abcdefghijklmnopqrstuvwxyz01", "npm_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] {
            #expect(!findings.contains { $0.allText.contains(secret) }, "a finding leaked \(secret)")
        }
        #expect(findings.contains { $0.allText.contains(Redactor.placeholder) })
    }

    @Test("No finding dumps an environment variable's value")
    func environmentValuesNeverAppear() async {
        var scenario = HealthyMachineDiagnosticsTests.scenario()
        scenario.environment["GITHUB_TOKEN"] = "ghp_shouldnotappearanywhere00000000"
        scenario.environment["AWS_SECRET_ACCESS_KEY"] = "macup-doctor-must-never-print-this"
        scenario.environment["NODE_OPTIONS"] = "--require /tmp/evil.js"
        // Something wrong in every area, so as many findings as possible exist.
        scenario.providers[0] = .failed(.homebrew, MacUpError(.commandFailed, "brew could not be run."))
        scenario.configurationIssues = [ConfigurationIssue(.error, "", "The configuration file could not be read.")]

        let findings = await HealthyMachineDiagnosticsTests.runAll(scenario.input)
        #expect(!findings.isEmpty)
        for value in ["ghp_shouldnotappearanywhere00000000", "macup-doctor-must-never-print-this", "--require /tmp/evil.js"] {
            #expect(!findings.contains { $0.allText.contains(value) }, "a finding leaked \(value)")
        }
    }

    @Test("Control characters in provider output cannot reach a terminal")
    func untrustedTextIsSanitized() async {
        var scenario = HealthyMachineDiagnosticsTests.scenario()
        scenario.providers[1] = .failed(.npm, MacUpError(
            .commandFailed,
            "npm printed \u{1B}[2J\u{202E}gnihtemos and stopped."
        ))

        let findings = await HealthyMachineDiagnosticsTests.runAll(scenario.input)
        #expect(findings.contains { $0.id == "provider.unusable" })
        for finding in findings {
            #expect(!finding.allText.unicodeScalars.contains(where: TerminalText.isUnsafe), "\(finding.id) is not safe to print")
        }
    }

    @Test("The home directory is abbreviated, so a report carries no username")
    func homeDirectoryIsAbbreviated() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.searchPath(["/Users/example/.homebrew/bin", "/usr/bin"])
        scenario.fileSystem.addExecutable("/Users/example/.homebrew/bin/brew")
        scenario.fileSystem.addDirectory(scenario.paths.stateDirectory)
        scenario.fileSystem.setOwnership(
            scenario.paths.stateDirectory,
            FileOwnership(uid: DoctorDiagnosticScenario.userID, gid: 20, mode: 0o777)
        )
        scenario.add(.available(
            .homebrew,
            executable: "/Users/example/.homebrew/bin/brew",
            facts: [ProviderFact(key: "prefix", label: "Prefix", value: "/Users/example/.homebrew")]
        ))

        let findings = await HealthyMachineDiagnosticsTests.runAll(scenario.input)
        #expect(findings.contains { $0.id == "homebrew.nonStandardPrefix" })
        #expect(findings.contains { $0.id == "paths.directoryWritableByOthers" })
        for finding in findings {
            #expect(!finding.allText.contains("/Users/example"), "\(finding.id) shows the home directory in full")
        }
        #expect(findings.contains { $0.allText.contains("~/.homebrew") })
    }
}

extension DiagnosticFinding {
    /// Every piece of text a finding shows a person, for assertions that
    /// nothing unsafe reaches any of them.
    fileprivate var allText: String {
        [title, detail ?? "", recommendation ?? ""].joined(separator: " ")
    }
}
