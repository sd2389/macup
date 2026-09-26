import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

private let miseNodeBin = "/Users/example/.local/share/mise/installs/node/24.19.0/bin"
private let miseNodeRoot = "/Users/example/.local/share/mise/installs/node/24.19.0/lib/node_modules"

@Suite("npm parsers")
struct NpmParserTests {
    let context = NpmParsers.Context(globalRoot: miseNodeRoot, ownership: nil, nodeManager: .mise)

    private func outdated(_ fixture: String, exitStatus: Int32 = 1) throws -> ProviderListing<UpdateCandidate> {
        try NpmParsers.parseOutdated(.fixture(try Fixture.text(fixture), exitStatus: exitStatus), context: context)
    }

    @Test("Real outdated output: scoped names, exit status 1 with valid JSON, npm itself")
    func realOutput() throws {
        let listing = try outdated("npm/outdated-global.json", exitStatus: 1)
        #expect(listing.elements.map(\.id.rawValue) == ["npm:@anthropic-ai/claude-code", "npm:corepack", "npm:npm"])
        let claude = listing.elements[0]
        #expect(claude.displayName == "@anthropic-ai/claude-code")
        #expect(claude.versionChange == .patch)
        #expect(claude.risk.level == .low)
        #expect(claude.details["location"] == miseNodeRoot + "/@anthropic-ai/claude-code")

        let npm = listing.elements[2]
        #expect(npm.signals == [.packageManagerSelfUpdate])
        #expect(npm.versionChange == .major)
        #expect(npm.risk.level == .high)
        #expect(npm.notes.contains { $0.contains("managed by mise") })
        #expect(listing.elements[1].signals == [.packageManagerSelfUpdate])
    }

    @Test("Nothing outdated: {} or empty output")
    func nothingOutdated() throws {
        #expect(try outdated("npm/outdated-none.json", exitStatus: 0).elements.isEmpty)
        let empty = try NpmParsers.parseOutdated(.fixture(""), context: context)
        #expect(empty.elements.isEmpty)
    }

    @Test("An installed version newer than the registry's latest is not an update")
    func newerThanLatest() throws {
        let listing = try outdated("npm/outdated-newer-than-latest.json")
        #expect(listing.elements.map(\.id.rawValue) == ["npm:prettier"])
        #expect(listing.findings.map(\.id) == ["npm.installedNewerThanAvailable", "npm.installedNewerThanAvailable"])
    }

    @Test("wanted differing from latest is explained")
    func wantedDiffers() throws {
        let listing = try outdated("npm/outdated-wanted-differs.json")
        #expect(listing.elements.first?.availableVersion == "2.0.0")
        #expect(listing.elements.first?.notes.first?.contains("wanted 1.9.0") == true)
    }

    @Test("Packages outside npm's global directory are skipped as ambiguous")
    func outsideRoot() throws {
        let listing = try outdated("npm/outdated-outside-root.json")
        #expect(listing.elements.map(\.id.rawValue) == ["npm:honest"])
        #expect(listing.findings.map(\.id) == ["npm.ambiguousOwnership"])
    }

    @Test("A listed package with no installed version is reported, not proposed")
    func missingCurrent() throws {
        let listing = try outdated("npm/outdated-missing-current.json")
        #expect(listing.elements.isEmpty)
        #expect(listing.findings.map(\.id) == ["npm.missingPackage"])
    }

    @Test("Hostile names: printable ones stay data, unsafe ones are skipped")
    func hostileNames() throws {
        let listing = try outdated("npm/outdated-hostile-names.json")
        #expect(listing.elements.map(\.id.name) == ["pkg; rm -rf ~"])
        #expect(listing.findings.count == 2)
    }

    @Test(
        "npm's JSON error objects become clear errors",
        arguments: [
            ("npm/outdated-error-enoent.json", "npm could not find a file or directory it needed."),
            ("npm/outdated-error-eacces.json", "npm was denied access to its global packages."),
            ("npm/outdated-error-network.json", "npm could not reach the package registry."),
        ]
    )
    func reportedErrors(fixture: String, message: String) throws {
        let error = #expect(throws: MacUpError.self) { try outdated(fixture) }
        #expect(error?.kind == .commandFailed)
        #expect(error?.message == message)
        #expect(error?.detail?.isEmpty == false)
    }

    @Test("Malformed output: parse failure on success, command failure otherwise")
    func malformed() throws {
        let text = try Fixture.text("npm/outdated-malformed.txt")
        let parseError = #expect(throws: MacUpError.self) {
            try NpmParsers.parseOutdated(.fixture(text, exitStatus: 0), context: context)
        }
        #expect(parseError?.kind == .parseFailed)
        let commandError = #expect(throws: MacUpError.self) {
            try NpmParsers.parseOutdated(.fixture(text, exitStatus: 1), context: context)
        }
        #expect(commandError?.kind == .commandFailed)
    }

    @Test("Valid JSON with an unexpected exit status is not trusted")
    func unexpectedExitStatus() throws {
        let error = #expect(throws: MacUpError.self) { try outdated("npm/outdated-global.json", exitStatus: 2) }
        #expect(error?.kind == .commandFailed)
    }

    @Test("Global inventory, including an empty tree and a tree with problems")
    func inventory() throws {
        let full = try NpmParsers.parseInventory(.fixture(try Fixture.text("npm/ls-global.json")), context: context)
        #expect(full.elements.map(\.id.rawValue) == ["npm:@anthropic-ai/claude-code", "npm:corepack", "npm:npm"])
        #expect(full.elements.first?.activeVersion == "2.1.282")

        let empty = try NpmParsers.parseInventory(.fixture(try Fixture.text("npm/ls-global-empty.json")), context: context)
        #expect(empty.elements.isEmpty)

        let problems = try NpmParsers.parseInventory(
            .fixture(try Fixture.text("npm/ls-global-problems.json"), exitStatus: 1),
            context: context
        )
        #expect(problems.elements.map(\.id.rawValue) == ["npm:pnpm", "npm:typescript"])
        #expect(problems.elements.last?.details["missing"] == "true")
        #expect(problems.elements.last?.installedVersions.isEmpty == true)
        #expect(problems.findings.map(\.id) == ["npm.globalTreeProblems"])
    }

    @Test("npmrc variable references are found")
    func npmrcVariables() {
        let npmrc = """
            //registry.npmjs.org/:_authToken=${NPM_TOKEN}
            @corp:registry=https://npm.corp.example/
            //npm.corp.example/:_authToken=${CORP_TOKEN?}
            prefix=${HOME}/.npm-global
            bogus=${not valid}
            """
        #expect(NpmProvider.referencedVariables(in: npmrc) == ["NPM_TOKEN", "CORP_TOKEN", "HOME"])
    }
}

@Suite("npm provider")
struct NpmProviderTests {
    let provider = NpmProvider()

    /// npm and node installed by mise, with an existing global directory.
    private func miseHarness() throws -> ProviderHarness {
        let harness = ProviderHarness(path: "\(miseNodeBin):/usr/bin:/bin")
        harness.fileSystem
            .addExecutable("\(miseNodeBin)/npm")
            .addExecutable("\(miseNodeBin)/node")
            .addDirectory(miseNodeRoot)
        harness.runner.register("npm", ["--version"], .success("11.17.0\n"))
        harness.runner.register("node", ["--version"], .success("v24.19.0\n"))
        harness.runner.register("npm", ["prefix", "-g"], .success("/Users/example/.local/share/mise/installs/node/24.19.0\n"))
        harness.runner.register("npm", ["root", "-g"], .success(miseNodeRoot + "\n"))
        harness.runner.register("npm", ["outdated", "-g", "--json"], .exit(1, standardOutput: try Fixture.text("npm/outdated-global.json")))
        harness.runner.register("npm", ["ls", "-g", "--json", "--depth=0"], .success(try Fixture.text("npm/ls-global.json")))
        return harness
    }

    @Test("npm absent: unavailable, nothing run")
    func absent() async {
        let harness = ProviderHarness()
        let status = await provider.detect(context: harness.context())
        #expect(status.availability == .unavailable)
        #expect(harness.requests.isEmpty)
    }

    @Test("npm without any node is a failed provider")
    func npmWithoutNode() async {
        let harness = ProviderHarness(path: "/usr/local/bin:/usr/bin:/bin")
        harness.fileSystem.addExecutable("/usr/local/bin/npm")
        let status = await provider.detect(context: harness.context())
        #expect(status.availability == .failed)
        #expect(status.error?.message.contains("no node executable") == true)
    }

    @Test("npm under mise: exact node, prefix, root, and ownership chain")
    func npmUnderMise() async throws {
        let harness = try miseHarness()
        let status = await provider.detect(context: harness.context())
        let installation = try #require(status.installation)
        #expect(installation.version == "11.17.0")
        #expect(installation.fact("nodePath") == "\(miseNodeBin)/node")
        #expect(installation.fact("nodeVersion") == "v24.19.0")
        #expect(installation.fact("nodeManager") == "mise")
        #expect(installation.fact("globalRoot") == miseNodeRoot)
        #expect(status.findings.isEmpty)

        let listing = try await provider.outdated(context: harness.context(installation: installation))
        #expect(listing.elements.count == 3)
        #expect(listing.elements[0].ownership?.summary == "npm 11.17.0 → Node v24.19.0 → mise")
    }

    @Test("A missing global directory means no packages, and npm is not asked")
    func missingGlobalRoot() async throws {
        let harness = ProviderHarness(path: "/Users/example/.local/bin:/usr/bin:/bin")
        harness.fileSystem
            .addSymlink("/Users/example/.local/bin/npm", to: "/Users/example/.hermes/node/bin/npm")
            .addExecutable("/Users/example/.hermes/node/bin/npm")
            .addSymlink("/Users/example/.local/bin/node", to: "/Users/example/.hermes/node/bin/node")
            .addExecutable("/Users/example/.hermes/node/bin/node")
        harness.runner.register("npm", ["--version"], .success("10.9.8\n"))
        harness.runner.register("node", ["--version"], .success("v22.23.2\n"))
        harness.runner.register("npm", ["prefix", "-g"], .success("/Users/example/.local\n"))
        harness.runner.register("npm", ["root", "-g"], .success("/Users/example/.local/lib/node_modules\n"))

        let status = await provider.detect(context: harness.context())
        #expect(status.availability == .available)
        #expect(status.findings.map(\.id) == ["npm.globalRootMissing"])
        #expect(status.installation?.fact("nodeManager") == NodeManager.unknown.displayName)

        let context = harness.context(installation: status.installation)
        #expect(try await provider.outdated(context: context).elements.isEmpty)
        #expect(try await provider.inventory(context: context).elements.isEmpty)
        #expect(!harness.arguments(for: "npm").contains { $0.first == "outdated" || $0.first == "ls" })
    }

    @Test("A node from elsewhere on PATH is flagged")
    func nodeNotNextToNpm() async {
        let harness = ProviderHarness(path: "/opt/homebrew/bin:\(miseNodeBin):/usr/bin:/bin")
        harness.fileSystem
            .addExecutable("/opt/homebrew/bin/npm")
            .addExecutable("\(miseNodeBin)/node")
        harness.runner.register("npm", ["--version"], .success("10.0.0\n"))
        harness.runner.register("node", ["--version"], .success("v24.19.0\n"))
        harness.runner.register("npm", ["prefix", "-g"], .success("/opt/homebrew\n"))
        harness.runner.register("npm", ["root", "-g"], .success("/opt/homebrew/lib/node_modules\n"))
        let status = await provider.detect(context: harness.context())
        #expect(status.findings.contains { $0.id == "npm.nodeNotNextToNpm" })
    }

    @Test("Commands run with the chosen node first on PATH and an allowlisted environment")
    func environment() async throws {
        let harness = try miseHarness()
        harness.environment["NPM_CONFIG_REGISTRY"] = "https://registry.example.com/"
        harness.environment["NPM_TOKEN"] = "npm_abcdefghijklmnopqrstuvwxyz0123456789"
        harness.environment["UNRELATED_SECRET"] = "hidden"
        harness.environment["NODE_OPTIONS"] = "--require /tmp/dummy.js"
        harness.environment["DYLD_INSERT_LIBRARIES"] = "/tmp/dummy.dylib"
        harness.fileSystem.addFile(
            "/Users/example/.npmrc",
            contents: "//registry.example.com/:_authToken=${NPM_TOKEN}\nnode-options=${NODE_OPTIONS}\nx=${DYLD_INSERT_LIBRARIES}\n"
        )
        let context = try await harness.detectedContext(provider)
        _ = try await provider.outdated(context: context)

        let request = try #require(harness.requests.first { $0.arguments.first == "outdated" })
        #expect(request.effect == .readOnly)
        #expect(request.environment["PATH"]?.hasPrefix(miseNodeBin + ":") == true)
        #expect(request.environment["npm_config_update_notifier"] == "false")
        #expect(request.environment["NPM_CONFIG_REGISTRY"] == "https://registry.example.com/")
        #expect(request.environment["NPM_TOKEN"] != nil, "referenced by ~/.npmrc")
        #expect(request.environment["UNRELATED_SECRET"] == nil)
        #expect(request.environment["NODE_OPTIONS"] == nil, "never forwarded, even when an npmrc references it")
        #expect(request.environment["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(request.environment["GITHUB_TOKEN"] == nil)
        #expect(request.workingDirectory?.path == "/Users/example")
    }

    @Test("A permission failure reported by npm surfaces as an error")
    func permissionFailure() async throws {
        let harness = try miseHarness()
        harness.runner.register("npm", ["outdated", "-g", "--json"], .exit(
            243,
            standardOutput: try Fixture.text("npm/outdated-error-eacces.json"),
            standardError: "npm error code EACCES\n"
        ))
        let context = try await harness.detectedContext(provider)
        let error = await #expect(throws: MacUpError.self) { try await provider.outdated(context: context) }
        #expect(error?.message == "npm was denied access to its global packages.")
    }

    @Test("Node managers are recognized from paths")
    func nodeManagers() {
        let home = "/Users/example"
        let mise = home + "/.local/share/mise"
        func classify(_ path: String, _ canonical: String? = nil) -> NodeManager {
            NodeManager.classify(path: path, canonicalPath: canonical ?? path, homeDirectory: home, miseDataDirectory: mise)
        }
        #expect(classify(mise + "/installs/node/24.19.0/bin/node") == .mise)
        #expect(classify(mise + "/shims/node") == .mise)
        #expect(classify("/opt/homebrew/bin/node", "/opt/homebrew/Cellar/node/24.1.0/bin/node") == .homebrew)
        #expect(classify(home + "/.nvm/versions/node/v20.11.0/bin/node") == .nvm)
        #expect(classify(home + "/.volta/bin/node") == .volta)
        #expect(classify(home + "/.asdf/shims/node") == .asdf)
        #expect(classify("/usr/local/bin/node") == .unknown)
        #expect(NodeManager.miseDataDirectory(environment: ["MISE_DATA_DIR": "/opt/mise/"], homeDirectory: home) == "/opt/mise")
        #expect(NodeManager.miseDataDirectory(environment: ["XDG_DATA_HOME": "/x"], homeDirectory: home) == "/x/mise")
    }
}
