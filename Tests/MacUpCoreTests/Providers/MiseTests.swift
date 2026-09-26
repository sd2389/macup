import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("mise parsers")
struct MiseParserTests {
    private func context(fileSystem: FakeFileSystem = FakeFileSystem(), environment: [String: String] = [:]) -> MiseParsers.Context {
        MiseParsers.Context(
            homeDirectory: "/Users/example",
            directories: MiseProvider.directories(environment: environment, homeDirectory: "/Users/example"),
            miseLink: OwnershipLink(label: "mise 2026.7.3", path: "/Users/example/.local/bin/mise"),
            fileSystem: fileSystem
        )
    }

    private func outdated(_ fixture: String, fileSystem: FakeFileSystem = FakeFileSystem()) throws -> ProviderListing<UpdateCandidate> {
        try MiseParsers.parseOutdated(Fixture.data(fixture), context: context(fileSystem: fileSystem))
    }

    @Test("Fuzzy requests in the global config stay within range")
    func globalFuzzy() throws {
        let listing = try outdated("mise/outdated-global-fuzzy.json")
        #expect(listing.elements.map(\.id.rawValue) == ["mise:node", "mise:python"])
        let node = listing.elements[0]
        #expect(node.installedVersion == "24.19.0")
        #expect(node.availableVersion == "24.21.0")
        #expect(node.versionChange == .minor)
        #expect(Set(node.signals) == [.runtimeOrToolchain, .mayAffectDependents])
        #expect(node.risk.level == .moderate)
        #expect(node.details["configScope"] == "global")
        #expect(node.details["requested"] == "24")
        #expect(node.notes.contains("Stays within the requested version \"24\"; the configuration file is not changed."))
        #expect(node.notes.contains { $0.contains("Global npm packages are installed per Node version") })
        #expect(node.ownership?.summary == "mise 2026.7.3 → global config")

        let python = listing.elements[1]
        #expect(python.versionChange == .patch)
        #expect(python.risk.level == .moderate, "runtime signal raises a patch to moderate")
    }

    @Test("Project-local configuration is labelled informational")
    func localProject() throws {
        let listing = try outdated("mise/outdated-local-project.json")
        let node = try #require(listing.elements.first)
        #expect(node.details["configScope"] == "project")
        #expect(node.notes.contains { $0.contains("MacUp treats project-local updates as informational") })
    }

    @Test("An exact pin is never bumped; reaching latest would need a config change")
    func exactPin() throws {
        let listing = try outdated("mise/outdated-exact-pin.json")
        let node = try #require(listing.elements.first)
        #expect(node.signals.contains(.mayRewriteConfiguration))
        #expect(node.risk.level == .high)
        #expect(node.notes.contains { $0.hasPrefix("Pinned to exactly 24.18.0") })
    }

    @Test("Older mise output without name, bump, or source still parses")
    func legacyFormat() throws {
        let listing = try outdated("mise/outdated-legacy-format.json")
        #expect(listing.elements.map(\.id.rawValue) == ["mise:python", "mise:terraform"])
        #expect(listing.elements.allSatisfy { $0.details["configScope"] == "unknown" })
        #expect(listing.elements[0].versionChange == .patch)
        #expect(listing.elements[1].notes.contains { $0.contains("\"latest\"") })
    }

    @Test("A requested but missing tool is reported, not proposed")
    func notInstalled() throws {
        let listing = try outdated("mise/outdated-not-installed.json")
        #expect(listing.elements.isEmpty)
        #expect(listing.findings.map(\.id) == ["mise.notInstalled"])
    }

    @Test("Home, unknown, and system scopes; backend-qualified tool names")
    func scopes() throws {
        let listing = try outdated("mise/outdated-scopes.json")
        let byName = Dictionary(uniqueKeysWithValues: listing.elements.map { ($0.id.name, $0) })
        #expect(byName["ruby"]?.details["configScope"] == "home")
        #expect(byName["ruby"]?.versionChange == .patch)
        #expect(byName["deno"]?.details["configScope"] == "unknown")
        #expect(byName["npm:prettier"]?.details["configScope"] == "system")
        #expect(byName["npm:prettier"]?.id.rawValue == "mise:npm:prettier")
        #expect(byName["npm:prettier"]?.signals.contains(.runtimeOrToolchain) == false)
    }

    @Test("A lockfile next to the config is flagged as possibly changing")
    func lockfile() throws {
        let fileSystem = FakeFileSystem().addFile("/Users/example/.config/mise/mise.lock")
        let listing = try outdated("mise/outdated-global-fuzzy.json", fileSystem: fileSystem)
        for candidate in listing.elements {
            #expect(candidate.signals.contains(.mayRewriteConfiguration))
            #expect(candidate.details["lockfile"] == "/Users/example/.config/mise/mise.lock")
        }
    }

    @Test("No updates, and malformed JSON")
    func noneAndMalformed() throws {
        #expect(try outdated("mise/outdated-none.json").elements.isEmpty)
        let error = #expect(throws: MacUpError.self) { try outdated("mise/outdated-malformed.json") }
        #expect(error?.kind == .parseFailed)
    }

    @Test("Inventory distinguishes active, inactive, and missing versions")
    func inventory() throws {
        let listing = try MiseParsers.parseInventory(Fixture.data("mise/ls.json"), context: context())
        let items = Dictionary(uniqueKeysWithValues: listing.elements.map { ($0.id.rawValue, $0) })
        let node = try #require(items["mise:node"])
        #expect(node.installedVersions == ["24.18.0", "24.19.0"])
        #expect(node.activeVersion == "24.19.0")
        #expect(node.details["inactiveVersions"] == "24.18.0")
        #expect(node.details["configScope"] == "global")
        let go = try #require(items["mise:go"])
        #expect(go.installedVersions.isEmpty)
        #expect(go.details["activeVersionMissing"] == "true")
    }

    @Test("Scope classification follows mise's directory variables")
    func scopeClassification() {
        let home = "/Users/example"
        let standard = MiseProvider.directories(environment: [:], homeDirectory: home)
        #expect(MiseProvider.scope(of: home + "/.config/mise/config.toml", type: "mise.toml", homeDirectory: home, directories: standard) == .global)
        #expect(MiseProvider.scope(of: home + "/.config/mise/conf.d/extra.toml", type: "mise.toml", homeDirectory: home, directories: standard) == .global)
        #expect(MiseProvider.scope(of: "/etc/mise/config.toml", type: "mise.toml", homeDirectory: home, directories: standard) == .system)
        #expect(MiseProvider.scope(of: home + "/.tool-versions", type: ".tool-versions", homeDirectory: home, directories: standard) == .home)
        #expect(MiseProvider.scope(of: home + "/src/app/mise.toml", type: "mise.toml", homeDirectory: home, directories: standard) == .project)
        #expect(MiseProvider.scope(of: nil, type: nil, homeDirectory: home, directories: standard) == .unknown)

        let custom = MiseProvider.directories(environment: ["MISE_CONFIG_DIR": "/opt/mise-config"], homeDirectory: home)
        #expect(custom.globalConfigFile == "/opt/mise-config/config.toml")
        #expect(MiseProvider.scope(of: home + "/.config/mise/config.toml", type: "mise.toml", homeDirectory: home, directories: custom) == .home)
    }
}

@Suite("mise provider")
struct MiseProviderTests {
    let provider = MiseProvider()

    private func harness() throws -> ProviderHarness {
        let harness = ProviderHarness(path: "/usr/bin:/bin")
        harness.fileSystem.addExecutable("/Users/example/.local/bin/mise")
        harness.runner.register("mise", ["--version"], .success(
            "2026.7.3 macos-arm64 (2026-07-08)\n",
            standardError: "mise WARN  mise version 2026.9.14 available\n"
        ))
        harness.runner.register("mise", ["outdated", "--json"], .success(try Fixture.text("mise/outdated-global-fuzzy.json")))
        harness.runner.register("mise", ["ls", "--json"], .success(try Fixture.text("mise/ls.json")))
        return harness
    }

    @Test("mise absent: unavailable, nothing run")
    func absent() async {
        let harness = ProviderHarness(path: "/usr/bin:/bin")
        let status = await provider.detect(context: harness.context())
        #expect(status.availability == .unavailable)
        #expect(harness.requests.isEmpty)
    }

    @Test("Found in its standard location; version parsed; stderr warnings ignored")
    func detection() async throws {
        let harness = try harness()
        let status = await provider.detect(context: harness.context())
        #expect(status.availability == .available)
        #expect(status.installation?.executable.source == .standardLocation)
        #expect(status.installation?.version == "2026.7.3")
        #expect(status.installation?.fact("globalConfigFile") == "/Users/example/.config/mise/config.toml")
    }

    @Test("Commands run from the home directory, never with --bump, with mise's environment only")
    func commandsAndEnvironment() async throws {
        let harness = try harness()
        harness.environment["MISE_EXPERIMENTAL"] = "1"
        let context = try await harness.detectedContext(provider)
        _ = try await provider.outdated(context: context)
        _ = try await provider.inventory(context: context)
        #expect(harness.arguments(for: "mise") == [["--version"], ["outdated", "--json"], ["ls", "--json"]])
        for request in harness.requests {
            #expect(request.workingDirectory?.path == "/Users/example")
            #expect(!request.arguments.contains("--bump"))
            #expect(request.environment["MISE_EXPERIMENTAL"] == "1")
            #expect(request.environment["GITHUB_TOKEN"] != nil, "mise uses it to avoid GitHub rate limits")
            #expect(request.environment["AWS_SECRET_ACCESS_KEY"] == nil)
        }
    }

    @Test("A failing mise command (for example an untrusted config) is surfaced")
    func failure() async throws {
        let harness = try harness()
        harness.runner.register("mise", ["outdated", "--json"], .exit(
            1,
            standardError: "mise ERROR Config files in ~/Projects/app/mise.toml are not trusted.\n"
        ))
        let context = try await harness.detectedContext(provider)
        let error = await #expect(throws: MacUpError.self) { try await provider.outdated(context: context) }
        #expect(error?.kind == .commandFailed)
        #expect(error?.detail?.contains("not trusted") == true)
    }

    @Test("Lookup problems on stderr of a successful check mark results incomplete; the update notice does not")
    func lookupProblemsOnSuccess() async throws {
        let harness = try harness()
        harness.runner.register("mise", ["outdated", "--json"], .success(
            "{}",
            standardError: "mise WARN  mise version 2026.9.14 available\nmise WARN  Error getting latest version for node: dummy lookup failure\n"
        ))
        let listing = try await provider.outdated(context: try await harness.detectedContext(provider))
        #expect(listing.elements.isEmpty)
        #expect(listing.partial)
        let finding = try #require(listing.findings.first { $0.id == "mise.outdatedWarnings" })
        #expect(finding.detail?.contains("dummy lookup failure") == true)
        #expect(finding.detail?.contains("available") == false)

        #expect(MiseProvider.lookupProblems(in: "mise WARN  mise version 2026.9.14 available\n") == nil)
        #expect(MiseProvider.lookupProblems(in: "") == nil)
    }
}
