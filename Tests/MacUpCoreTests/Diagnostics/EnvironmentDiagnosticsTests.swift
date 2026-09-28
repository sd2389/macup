import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Doctor: Homebrew installations")
struct HomebrewInstallationCheckTests {
    private let check = HomebrewInstallationCheck()

    @Test("Two Homebrew installations are reported, naming the one MacUp uses")
    func twoInstallationsAreReported() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.searchPath(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])
        scenario.fileSystem.addExecutable("/opt/homebrew/bin/brew")
        scenario.fileSystem.addExecutable("/usr/local/bin/brew")
        scenario.add(.available(.homebrew, executable: "/opt/homebrew/bin/brew"))

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["homebrew.multipleInstallations"])
        #expect(findings[0].severity == .warning)
        #expect(findings[0].detail?.contains("MacUp uses /opt/homebrew/bin/brew") == true)
        #expect(findings[0].detail?.contains("/usr/local/bin/brew") == true)
    }

    @Test("The Homebrew provider's own report of two installations is not repeated")
    func providerFindingIsNotRepeated() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.searchPath(["/opt/homebrew/bin", "/usr/local/bin"])
        scenario.fileSystem.addExecutable("/opt/homebrew/bin/brew")
        scenario.fileSystem.addExecutable("/usr/local/bin/brew")
        scenario.add(.available(
            .homebrew,
            executable: "/opt/homebrew/bin/brew",
            findings: [DiagnosticFinding(
                id: "homebrew.multipleInstallations",
                severity: .warning,
                provider: .homebrew,
                title: "More than one Homebrew installation was found"
            )]
        ))

        #expect(await check.run(scenario.input).isEmpty)
    }

    @Test("Homebrew in a custom prefix is explained, because only PATH leads to it")
    func customPrefixIsExplained() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.searchPath(["/Users/example/.homebrew/bin", "/usr/bin"])
        scenario.fileSystem.addExecutable("/Users/example/.homebrew/bin/brew")
        scenario.add(.available(
            .homebrew,
            executable: "/Users/example/.homebrew/bin/brew",
            facts: [ProviderFact(key: "prefix", label: "Prefix", value: "/Users/example/.homebrew")]
        ))

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["homebrew.nonStandardPrefix"])
        #expect(findings[0].severity == .info)
        #expect(findings[0].detail?.contains("~/.homebrew/bin/brew") == true)
        #expect(findings[0].detail?.contains("with the prefix ~/.homebrew") == true)
        // The home directory never appears in a finding, so a report is safe to paste.
        #expect(findings[0].detail?.contains("/Users/example") == false)
    }

    @Test("One Homebrew in its usual location produces nothing")
    func singleStandardInstallationIsSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.searchPath(["/opt/homebrew/bin", "/usr/bin"])
        scenario.fileSystem.addExecutable("/opt/homebrew/bin/brew")
        scenario.add(.available(.homebrew, executable: "/opt/homebrew/bin/brew"))

        #expect(await check.run(scenario.input).isEmpty)
    }

    @Test("Nothing is said about Homebrew while it is turned off")
    func disabledHomebrewIsSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.searchPath(["/opt/homebrew/bin", "/usr/local/bin"])
        scenario.fileSystem.addExecutable("/opt/homebrew/bin/brew")
        scenario.fileSystem.addExecutable("/usr/local/bin/brew")
        scenario.add(.disabled(.homebrew))

        #expect(await check.run(scenario.input).isEmpty)
    }
}

@Suite("Doctor: login shell environment")
struct ShellEnvironmentCheckTests {
    /// A reader that answers with a fixed shell environment instead of
    /// starting a login shell.
    private func reader(path: String, shell: String = "/bin/zsh") -> ShellEnvironmentCheck.Reader {
        { _ in (shell, ["PATH": path]) }
    }

    @Test("Directories the shell has and MacUp does not are reported as a warning")
    func missingDirectoriesAreReported() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.environment["PATH"] = "/usr/bin:/bin"
        let check = ShellEnvironmentCheck(read: reader(path: "/Users/example/.homebrew/bin:/usr/bin:/bin"))

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["environment.pathDiffersFromLoginShell"])
        #expect(findings[0].severity == .warning)
        #expect(findings[0].detail?.contains("zsh has ~/.homebrew/bin, which MacUp did not.") == true)
        #expect(findings[0].recommendation?.contains("one MacUp will not find") == true)
    }

    @Test("Directories MacUp has and the shell does not are information, not a warning")
    func extraDirectoriesAreInformation() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.environment["PATH"] = "/opt/homebrew/bin:/usr/bin"
        let check = ShellEnvironmentCheck(read: reader(path: "/usr/bin"))

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["environment.pathDiffersFromLoginShell"])
        #expect(findings[0].severity == .info)
        #expect(findings[0].detail?.contains("MacUp had /opt/homebrew/bin, which zsh did not.") == true)
    }

    @Test("A login shell MacUp could not read is a warning, not a silent fallback")
    func unreadableShellIsReported() async {
        let scenario = DoctorDiagnosticScenario()
        let check = ShellEnvironmentCheck(read: { _ in
            throw MacUpError.parseFailed("Your login shell did not report its environment.")
        })

        let findings = await check.run(scenario.input)
        #expect(findings.map(\.id) == ["environment.loginShellUnreadable"])
        #expect(findings[0].severity == .warning)
        #expect(findings[0].detail?.contains("did not report its environment") == true)
    }

    @Test("A PATH that matches the login shell's produces nothing")
    func matchingPathIsSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.environment["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin"
        let check = ShellEnvironmentCheck(read: reader(path: "/opt/homebrew/bin:/usr/bin:/bin"))

        #expect(await check.run(scenario.input).isEmpty)
    }

    @Test("A PATH with the same directories in a different order is not a difference")
    func reorderedPathIsSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.environment["PATH"] = "/usr/bin:/opt/homebrew/bin"
        let check = ShellEnvironmentCheck(read: reader(path: "/opt/homebrew/bin:/usr/bin"))

        #expect(await check.run(scenario.input).isEmpty)
    }
}

@Suite("Doctor: runtime ownership")
struct RuntimeOwnershipCheckTests {
    private let check = RuntimeOwnershipCheck()
    private let miseNode = "/Users/example/.local/share/mise/installs/node/24.19.0/bin/node"

    /// A Mac where a Node installed elsewhere shadows the one mise reports as
    /// active — the situation `mise ls` and `node --version` disagree about.
    private func shadowedNode() -> DoctorDiagnosticScenario {
        var scenario = DoctorDiagnosticScenario()
        scenario.searchPath([
            "/Users/example/.local/bin",
            "/Users/example/.local/share/mise/installs/node/24.19.0/bin",
            "/usr/bin",
        ])
        scenario.fileSystem.addExecutable("/Users/example/.hermes/node/bin/node")
        scenario.fileSystem.addSymlink("/Users/example/.local/bin/node", to: "/Users/example/.hermes/node/bin/node")
        scenario.fileSystem.addExecutable(miseNode)
        scenario.add(.available(
            .mise,
            executable: "/Users/example/.local/bin/mise",
            items: [.miseTool("node", active: "24.19.0", configPath: "/Users/example/.config/mise/config.toml")]
        ))
        return scenario
    }

    @Test("mise's active Node being shadowed on PATH is a warning that names both")
    func shadowedActiveVersionIsReported() async {
        let findings = await check.run(shadowedNode().input)
        let shadowed = findings.first { $0.id == "runtime.activeVersionShadowedOnPath" }
        #expect(shadowed?.severity == .warning)
        #expect(shadowed?.provider == .mise)
        #expect(shadowed?.title == "mise's active node is not the node your PATH finds first")
        #expect(shadowed?.detail?.contains("mise reports node 24.19.0 active") == true)
        #expect(shadowed?.detail?.contains("requested in ~/.config/mise/config.toml") == true)
        #expect(shadowed?.detail?.contains("The first node on your PATH is ~/.local/bin/node") == true)
        #expect(shadowed?.detail?.contains("resolves to ~/.hermes/node/bin/node") == true)
        #expect(shadowed?.detail?.contains("A mise-managed copy is further along your PATH") == true)
        // An installation MacUp cannot attribute is described as one, rather
        // than credited to a tool called "unrecognized".
        #expect(shadowed?.detail?.contains("from an installation MacUp does not recognize") == true)
        #expect(shadowed?.detail?.contains("installed by unrecognized") == false)
    }

    @Test("The Node warning says where global npm packages actually live")
    func nodeRecommendationNamesGlobalPackages() async {
        let findings = await check.run(shadowedNode().input)
        let shadowed = findings.first { $0.id == "runtime.activeVersionShadowedOnPath" }
        #expect(shadowed?.recommendation?.contains("Global npm packages belong to the Node that runs npm") == true)
    }

    @Test("Several installations of one runtime on PATH are listed in the order a shell searches")
    func multipleInstallationsAreListedInOrder() async {
        let findings = await check.run(shadowedNode().input)
        let multiple = findings.first { $0.id == "runtime.multipleInstallationsOnPath" }
        #expect(multiple?.severity == .info)
        let detail = try? #require(multiple?.detail)
        let first = detail?.range(of: "~/.local/bin/node")
        let second = detail?.range(of: "~/.local/share/mise/installs/node/24.19.0/bin/node")
        #expect(first != nil && second != nil)
        if let first, let second { #expect(first.lowerBound < second.lowerBound) }
        #expect(detail?.contains("(mise)") == true)
    }

    @Test("A Homebrew Python ahead of mise's active Python is reported the same way")
    func shadowedPythonIsReported() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.searchPath([
            "/Users/example/.homebrew/bin",
            "/Users/example/.local/share/mise/installs/python/3.14.6/bin",
            "/usr/bin",
        ])
        scenario.fileSystem.addExecutable("/Users/example/.homebrew/Cellar/python@3.14/3.14.7/bin/python3")
        scenario.fileSystem.addSymlink(
            "/Users/example/.homebrew/bin/python3",
            to: "/Users/example/.homebrew/Cellar/python@3.14/3.14.7/bin/python3"
        )
        scenario.fileSystem.addExecutable("/Users/example/.local/share/mise/installs/python/3.14.6/bin/python3")
        scenario.fileSystem.addExecutable("/usr/bin/python3")
        scenario.add(.available(
            .homebrew,
            executable: "/Users/example/.homebrew/bin/brew",
            facts: [ProviderFact(key: "prefix", label: "Prefix", value: "/Users/example/.homebrew")]
        ))
        scenario.add(.available(
            .mise,
            executable: "/Users/example/.local/bin/mise",
            items: [.miseTool("python", active: "3.14.6")]
        ))

        let findings = await check.run(scenario.input)
        let shadowed = findings.first { $0.id == "runtime.activeVersionShadowedOnPath" }
        #expect(shadowed?.severity == .warning)
        #expect(shadowed?.detail?.contains("installed by Homebrew") == true)
        #expect(shadowed?.recommendation?.contains("Global npm packages") == false)

        let multiple = findings.first { $0.id == "runtime.multipleInstallationsOnPath" }
        #expect(multiple?.detail?.contains("(macOS)") == true)
    }

    @Test("A runtime whose only installation is the one mise manages produces nothing")
    func miseManagedRuntimeIsSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.searchPath(["/Users/example/.local/share/mise/installs/node/24.19.0/bin", "/usr/bin"])
        scenario.fileSystem.addExecutable(miseNode)
        scenario.add(.available(
            .mise,
            executable: "/Users/example/.local/bin/mise",
            items: [.miseTool("node", active: "24.19.0")]
        ))

        #expect(await check.run(scenario.input).isEmpty)
    }

    @Test("A runtime MacUp cannot match to a command name is left alone")
    func unknownRuntimeIsSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.searchPath(["/usr/bin"])
        scenario.fileSystem.addExecutable("/usr/bin/erl")
        scenario.add(.available(
            .mise,
            executable: "/Users/example/.local/bin/mise",
            items: [.miseTool("erlang", active: "27.0")]
        ))

        #expect(await check.run(scenario.input).isEmpty)
    }
}

@Suite("Doctor: npm ownership")
struct NpmOwnershipCheckTests {
    private let check = NpmOwnershipCheck()
    private let miseNode = "/Users/example/.local/share/mise/installs/node/24.19.0/bin/node"

    private func npmReport(nodePath: String, nodeTarget: String?, prefix: String, root: String) -> ProviderReport {
        var facts = [
            ProviderFact(key: NpmProvider.FactKey.nodePath, label: "Node", value: nodePath),
            ProviderFact(key: NpmProvider.FactKey.nodeVersion, label: "Node version", value: "v22.23.2"),
            ProviderFact(key: NpmProvider.FactKey.nodeManager, label: "Node managed by", value: "unrecognized"),
            ProviderFact(key: NpmProvider.FactKey.globalPrefix, label: "Global prefix", value: prefix),
            ProviderFact(key: NpmProvider.FactKey.globalRoot, label: "Global packages", value: root),
        ]
        if let nodeTarget {
            facts.insert(ProviderFact(key: NpmProvider.FactKey.nodeTarget, label: "Node resolves to", value: nodeTarget), at: 1)
        }
        return .available(.npm, executable: "/Users/example/.local/bin/npm", facts: facts)
    }

    @Test("npm running a Node that mise does not manage is a warning that names both")
    func npmNodeOutsideMiseIsReported() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(npmReport(
            nodePath: "/Users/example/.local/bin/node",
            nodeTarget: "/Users/example/.hermes/node/bin/node",
            prefix: "/Users/example/.local",
            root: "/Users/example/.local/lib/node_modules"
        ))
        scenario.add(.available(
            .mise,
            executable: "/Users/example/.local/bin/mise",
            items: [.miseTool("node", active: "24.19.0")]
        ))

        let findings = await check.run(scenario.input)
        let finding = findings.first { $0.id == "npm.nodeNotManagedByMise" }
        #expect(finding?.severity == .warning)
        #expect(finding?.provider == .npm)
        #expect(finding?.detail?.contains("mise reports node 24.19.0 active") == true)
        #expect(finding?.detail?.contains("runs ~/.hermes/node/bin/node (v22.23.2)") == true)
        #expect(finding?.detail?.contains("installed by unrecognized") == false)
        #expect(finding?.detail?.contains("global packages MacUp lists are the ones in ~/.local/lib/node_modules") == true)
        #expect(finding?.recommendation?.contains("belong to one Node installation") == true)
    }

    @Test("A global prefix outside the Node installation is explained as information")
    func customGlobalPrefixIsExplained() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(npmReport(
            nodePath: "/Users/example/.local/bin/node",
            nodeTarget: "/Users/example/.hermes/node/bin/node",
            prefix: "/Users/example/.local",
            root: "/Users/example/.local/lib/node_modules"
        ))

        let findings = await check.run(scenario.input)
        let finding = findings.first { $0.id == "npm.globalPrefixOutsideNode" }
        #expect(finding?.severity == .info)
        #expect(finding?.detail?.contains("global prefix is ~/.local") == true)
        #expect(finding?.detail?.contains("Node that runs npm lives under ~/.hermes/node") == true)
        #expect(finding?.recommendation?.contains("~/.local/bin is on your PATH") == true)
    }

    @Test("npm running mise's own active Node produces nothing")
    func npmUnderMiseIsSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.available(
            .npm,
            executable: "/Users/example/.local/share/mise/installs/node/24.19.0/bin/npm",
            facts: [
                ProviderFact(key: NpmProvider.FactKey.nodePath, label: "Node", value: miseNode),
                ProviderFact(key: NpmProvider.FactKey.globalPrefix, label: "Global prefix", value: "/Users/example/.local/share/mise/installs/node/24.19.0"),
                ProviderFact(key: NpmProvider.FactKey.globalRoot, label: "Global packages", value: "/Users/example/.local/share/mise/installs/node/24.19.0/lib/node_modules"),
            ]
        ))
        scenario.add(.available(
            .mise,
            executable: "/Users/example/.local/bin/mise",
            items: [.miseTool("node", active: "24.19.0")]
        ))

        #expect(await check.run(scenario.input).isEmpty)
    }

    @Test("Without mise, a Node with its own prefix produces nothing")
    func plainNodeInstallationIsSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.available(
            .npm,
            executable: "/opt/homebrew/bin/npm",
            facts: [
                ProviderFact(key: NpmProvider.FactKey.nodePath, label: "Node", value: "/opt/homebrew/bin/node"),
                ProviderFact(key: NpmProvider.FactKey.globalPrefix, label: "Global prefix", value: "/opt/homebrew"),
                ProviderFact(key: NpmProvider.FactKey.globalRoot, label: "Global packages", value: "/opt/homebrew/lib/node_modules"),
            ]
        ))

        #expect(await check.run(scenario.input).isEmpty)
    }

    @Test("Nothing is said when npm is not installed")
    func absentNpmIsSilent() async {
        var scenario = DoctorDiagnosticScenario()
        scenario.add(.notInstalled(.npm))
        scenario.add(.available(
            .mise,
            executable: "/Users/example/.local/bin/mise",
            items: [.miseTool("node", active: "24.19.0")]
        ))

        #expect(await check.run(scenario.input).isEmpty)
    }
}
