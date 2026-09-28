import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Doctor: provider availability")
struct ProviderAvailabilityCheckTests {
    private let check = ProviderAvailabilityCheck()

    @Test("A provider that is simply not installed is reported as information, not a fault")
    func notInstalledIsNotAnError() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.notInstalled(.mise))

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["provider.notFound"])
        #expect(findings[0].severity == .info)
        #expect(findings[0].provider == .mise)
        #expect(findings[0].title == "mise is not installed")
        #expect(findings[0].detail == "MacUp did not find mise on your PATH or where it is usually installed.")
        #expect(findings[0].recommendation?.contains("Nothing is wrong") == true)
    }

    @Test("Where MacUp looked is shown when detection recorded it")
    func searchedLocationsAreShownWhenKnown() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.notInstalled(.mise, detail: "Searched: /opt/homebrew/bin, /usr/bin"))

        let findings = await check.run(scenario.input)
        #expect(findings[0].detail?.contains("/opt/homebrew/bin") == true)
    }

    @Test("A provider MacUp found but will not run from an untrusted location is a warning")
    func untrustedLocationIsAWarning() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.failed(.homebrew, MacUpError(
            .ambiguousOwnership,
            "Homebrew was found only at /usr/local/bin/brew, which MacUp does not run on its own: "
                + "/usr/local/bin is writable by other users.",
            recoverySuggestion: "If you trust it, add its directory to your PATH."
        )))

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["provider.locationNotTrusted"])
        #expect(findings[0].severity == .warning)
        #expect(findings[0].detail?.contains("writable by other users") == true)
        #expect(findings[0].recommendation?.contains("add its directory to your PATH") == true)
    }

    @Test("A configured executable path that cannot be used is an error against the configuration")
    func configuredPathIsAnError() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.failed(.npm, MacUpError(
            .configurationInvalid,
            "The configured npm path cannot be used: The configured path must be absolute."
        )))

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["provider.configuredPathUnusable"])
        #expect(findings[0].severity == .error)
    }

    @Test("A provider that was found but could not be run is an error")
    func unusableProviderIsAnError() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.failed(.mise, MacUpError(.commandFailed, "mise was found but `mise --version` failed.")))

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["provider.unusable"])
        #expect(findings[0].severity == .error)
    }

    @Test("A provider turned off in the configuration is explained, not blamed")
    func disabledProviderIsExplained() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.disabled(.macos))

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["provider.disabled"])
        #expect(findings[0].severity == .info)
        #expect(findings[0].recommendation?.contains("macup provider enable macos") == true)
    }

    @Test("A provider that was found and ran produces nothing")
    func availableProviderIsSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.available(.homebrew, executable: "/opt/homebrew/bin/brew"))

        #expect(await check.run(scenario.input).isEmpty)
    }
}

@Suite("Doctor: provider results")
struct ProviderResultsCheckTests {
    private let check = ProviderResultsCheck()

    @Test("A provider whose output could not be parsed is an error that names the operation")
    func parseFailureIsReported() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.available(
            .homebrew,
            executable: "/opt/homebrew/bin/brew",
            updateCount: nil,
            errors: [ProviderOperationError(
                operation: .outdated,
                error: MacUpError.parseFailed("Homebrew's outdated list was not valid JSON.")
            )]
        ))

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["provider.operationFailed"])
        #expect(findings[0].severity == .error)
        #expect(findings[0].title == "MacUp could not check for updates from Homebrew")
        #expect(findings[0].recommendation?.contains("will not guess") == true)
    }

    @Test("A failed inventory and a failed update check are reported separately")
    func everyFailedOperationIsReported() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.available(
            .npm,
            executable: "/usr/local/bin/npm",
            errors: [
                ProviderOperationError(operation: .inventory, error: MacUpError(.commandFailed, "`npm ls` failed.")),
                ProviderOperationError(operation: .outdated, error: MacUpError(.commandFailed, "`npm outdated` failed.")),
            ]
        ))

        let findings = await check.run(scenario.input)
        #expect(findings.count == 2)
        #expect(findings.allSatisfy { $0.id == "provider.operationFailed" })
        #expect(findings[0].title.contains("list what is installed by npm"))
        #expect(findings[1].title.contains("check for updates from npm"))
    }

    @Test("A detection failure is left to the availability check")
    func detectionFailureIsNotRepeated() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.failed(.mise, MacUpError(.commandFailed, "mise was found but could not be run.")))

        #expect(await check.run(scenario.input).isEmpty)
    }

    @Test("Results known to be incomplete are reported when nothing else explained why")
    func unexplainedIncompleteResultsAreReported() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.available(
            .mise,
            executable: "/usr/local/bin/mise",
            updateCount: 2,
            unreadableUpdates: 3,
            resultsIncomplete: true
        ))

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["provider.resultsIncomplete"])
        #expect(findings[0].severity == .warning)
        #expect(findings[0].detail?.contains("3 of the entries") == true)
    }

    @Test("Incomplete results the provider already explained are not repeated")
    func explainedIncompleteResultsAreSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.available(
            .mise,
            executable: "/usr/local/bin/mise",
            resultsIncomplete: true,
            findings: [DiagnosticFinding(
                id: "mise.outdatedWarnings",
                severity: .warning,
                provider: .mise,
                title: "mise reported problems while checking for updates"
            )]
        ))

        #expect(await check.run(scenario.input).isEmpty)
    }

    @Test("A provider with complete results produces nothing")
    func completeResultsAreSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.available(.homebrew, executable: "/opt/homebrew/bin/brew", updateCount: 4))

        #expect(await check.run(scenario.input).isEmpty)
    }
}

@Suite("Doctor: executable architecture")
struct ExecutableArchitectureCheckTests {
    @Test("An Intel provider binary on an Apple Silicon Mac is a warning about Rosetta")
    func intelBinaryOnAppleSilicon() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.available(.mise, executable: "/usr/local/bin/mise"))
        let reader = FakeArchitectureReader().set("/usr/local/bin/mise", .machO(["x86_64"]))

        let findings = await ExecutableArchitectureCheck(reader: reader).run(scenario.input)
        #expect(findings.map(\.id) == ["provider.architectureMismatch"])
        #expect(findings[0].severity == .warning)
        #expect(findings[0].title == "The mise executable is an Intel binary on an Apple Silicon Mac")
        #expect(findings[0].detail?.contains("built for x86_64; this Mac is arm64") == true)
        #expect(findings[0].recommendation?.contains("Rosetta 2") == true)
    }

    @Test("An Apple Silicon binary on an Intel Mac cannot run and is an error")
    func appleSiliconBinaryOnIntel() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.system = SystemInfo(productVersion: "14.7", buildVersion: nil, architecture: "x86_64")
        scenario.add(.available(.mise, executable: "/opt/homebrew/bin/mise"))
        let reader = FakeArchitectureReader().set("/opt/homebrew/bin/mise", .machO(["arm64"]))

        let findings = await ExecutableArchitectureCheck(reader: reader).run(scenario.input)
        #expect(findings.map(\.id) == ["provider.architectureMismatch"])
        #expect(findings[0].severity == .error)
        #expect(findings[0].recommendation?.contains("Reinstall the tool for x86_64") == true)
    }

    @Test("The Node that runs npm is checked, because npm itself is a script")
    func npmsNodeIsChecked() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.available(
            .npm,
            executable: "/usr/local/bin/npm",
            facts: [
                ProviderFact(key: NpmProvider.FactKey.nodePath, label: "Node", value: "/usr/local/bin/node"),
                ProviderFact(key: NpmProvider.FactKey.nodeTarget, label: "Node resolves to", value: "/usr/local/n/versions/node/20.0.0/bin/node"),
            ]
        ))
        let reader = FakeArchitectureReader()
            .set("/usr/local/n/versions/node/20.0.0/bin/node", .machO(["x86_64"]))

        let findings = await ExecutableArchitectureCheck(reader: reader).run(scenario.input)
        #expect(findings.map(\.id) == ["provider.architectureMismatch"])
        #expect(findings[0].title == "The Node that runs npm is an Intel binary on an Apple Silicon Mac")
        #expect(findings[0].provider == .npm)
    }

    @Test("A universal binary and a script both produce nothing")
    func matchingBinariesAreSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.available(.homebrew, executable: "/opt/homebrew/bin/brew"))
        scenario.add(.available(.mise, executable: "/opt/homebrew/bin/mise"))
        let reader = FakeArchitectureReader()
            .set("/opt/homebrew/bin/brew", .notMachO)
            .set("/opt/homebrew/bin/mise", .machO(["x86_64", "arm64"]))

        #expect(await ExecutableArchitectureCheck(reader: reader).run(scenario.input).isEmpty)
    }

    @Test("A header MacUp cannot interpret is left unreported rather than guessed at")
    func undeterminedArchitectureIsSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.available(.mise, executable: "/opt/homebrew/bin/mise"))
        let reader = FakeArchitectureReader(fallback: .undetermined)

        #expect(await ExecutableArchitectureCheck(reader: reader).run(scenario.input).isEmpty)
    }

    @Test("Nothing is compared when MacUp does not recognize the Mac's own architecture")
    func unknownHostArchitectureIsSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.system = SystemInfo(productVersion: "27.0", buildVersion: nil, architecture: "unknown")
        scenario.add(.available(.mise, executable: "/opt/homebrew/bin/mise"))
        let reader = FakeArchitectureReader().set("/opt/homebrew/bin/mise", .machO(["x86_64"]))

        #expect(await ExecutableArchitectureCheck(reader: reader).run(scenario.input).isEmpty)
    }
}
