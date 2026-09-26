import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Homebrew outdated parser")
struct HomebrewOutdatedParserTests {
    private func parse(_ fixture: String) throws -> ProviderListing<UpdateCandidate> {
        try HomebrewOutdatedParser.parse(Fixture.data(fixture), ownership: nil)
    }

    private func candidate(_ listing: ProviderListing<UpdateCandidate>, _ id: String) throws -> UpdateCandidate {
        try #require(listing.elements.first { $0.id.rawValue == id }, "no candidate \(id)")
    }

    @Test("Formula updates (real Homebrew 7 output shape)")
    func formulae() throws {
        let listing = try parse("homebrew/outdated-formula.json")
        #expect(listing.elements.map(\.id.rawValue) == ["brew:mysql", "brew:git"])
        #expect(listing.findings.isEmpty)
        let mysql = try candidate(listing, "brew:mysql")
        #expect(mysql.kind == .formula)
        #expect(mysql.installedVersion == "9.7.1")
        #expect(mysql.availableVersion == "26.7.0_2")
        #expect(mysql.versionChange == .major)
        #expect(mysql.risk.level == .high)
        let git = try candidate(listing, "brew:git")
        #expect(git.versionChange == .minor)
        #expect(git.risk.level == .moderate)
    }

    @Test("Cask updates use the brew-cask namespace")
    func casks() throws {
        let listing = try parse("homebrew/outdated-cask.json")
        #expect(listing.elements.map(\.id.rawValue) == ["brew-cask:visual-studio-code", "brew-cask:firefox"])
        #expect(listing.elements.allSatisfy { $0.kind == .cask })
    }

    @Test("Formulae and casks together: runtimes, taps, and package managers")
    func both() throws {
        let listing = try parse("homebrew/outdated-both.json")
        #expect(listing.elements.count == 5)
        let node = try candidate(listing, "brew:node@20")
        #expect(node.signals == [.runtimeOrToolchain])
        #expect(node.risk.level == .moderate)
        let python = try candidate(listing, "brew:python@3.12")
        #expect(python.versionChange == .patch)
        #expect(python.signals.contains(.runtimeOrToolchain))
        #expect(try candidate(listing, "brew:example-org/tools/widget").displayName == "example-org/tools/widget")
        #expect(try candidate(listing, "brew:mise").signals.contains(.packageManagerSelfUpdate))
        #expect(try candidate(listing, "brew-cask:codex").versionChange == .major) // 0.x minor bump
    }

    @Test("No updates")
    func none() throws {
        let listing = try parse("homebrew/outdated-none.json")
        #expect(listing.elements.isEmpty)
        #expect(listing.findings.isEmpty)
    }

    @Test("Pins are reflected and make updates high risk; MacUp never unpins")
    func pinned() throws {
        let listing = try parse("homebrew/outdated-pinned.json")
        for item in listing.elements {
            #expect(item.signals.contains(.pinnedByProvider))
            #expect(item.risk.level == .high)
            #expect(item.notes.contains { $0.contains("never unpins") })
        }
        #expect(try candidate(listing, "brew:postgresql@16").details["pinnedVersion"] == "16.1")
        #expect(try candidate(listing, "brew-cask:docker-desktop").versionChange == .unknown)
    }

    @Test("Schema additions, string installed_versions, several installed versions, and HEAD")
    func schemaAdditions() throws {
        let listing = try parse("homebrew/outdated-schema-additions.json")
        let wget = try candidate(listing, "brew:wget")
        #expect(wget.installedVersion == "1.21.4")
        #expect(wget.details["installedVersions"] == "1.21.3, 1.21.4")
        let neovim = try candidate(listing, "brew:neovim")
        #expect(neovim.versionChange == .unknown)
        #expect(neovim.risk.level == .unknown)
        #expect(try candidate(listing, "brew-cask:iterm2").installedVersion == "3.4.23")
    }

    @Test("Unusual but printable names are kept verbatim; unsafe names are skipped with findings")
    func unusualNames() throws {
        let listing = try parse("homebrew/outdated-unusual-names.json")
        #expect(Set(listing.elements.map(\.id.name)) == [
            "libsigc++", "gtk+3", "tool-\u{FC}n\u{EF}c\u{F8}d\u{E9}",
            "name; rm -rf ~", "$(touch /tmp/macup-pwned)", "`id`",
        ])
        #expect(listing.findings.count == 4)
        #expect(listing.findings.allSatisfy { $0.id == "homebrew.unusableName" })
        for finding in listing.findings {
            #expect(!(finding.detail ?? "").unicodeScalars.contains(where: TerminalText.isUnsafe))
        }
    }

    @Test("Entries missing required fields are skipped with findings, not guessed")
    func missingFields() throws {
        let listing = try parse("homebrew/outdated-missing-fields.json")
        #expect(listing.elements.map(\.id.rawValue) == ["brew:ripgrep"])
        #expect(listing.findings.count == 3)
    }

    @Test("Malformed JSON and unexpected shapes are parse failures", arguments: [
        "homebrew/outdated-malformed.json", "homebrew/outdated-wrong-shape.json",
    ])
    func malformed(fixture: String) throws {
        let error = #expect(throws: MacUpError.self) { try parse(fixture) }
        #expect(error?.kind == .parseFailed)
    }

    @Test("Newest installed version is chosen by comparison, not position")
    func newest() {
        #expect(HomebrewOutdatedParser.newest(["1.10.0", "1.9.0"]) == "1.10.0")
        #expect(HomebrewOutdatedParser.newest(["HEAD-abc", "weird"]) == "weird")
    }
}

@Suite("Homebrew inventory parser")
struct HomebrewInventoryParserTests {
    @Test("Formulae and casks from brew info --json=v2 --installed")
    func inventory() throws {
        let listing = try HomebrewInventoryParser.parse(Fixture.data("homebrew/info-installed.json"), ownership: nil)
        #expect(listing.elements.map(\.id.rawValue) == [
            "brew:git", "brew:abseil", "brew:postgresql@16", "brew:example-org/tools/widget",
            "brew-cask:firefox", "brew-cask:zoom",
        ])
        let items = Dictionary(uniqueKeysWithValues: listing.elements.map { ($0.id.rawValue, $0) })
        #expect(items["brew:git"]?.activeVersion == "2.43.0")
        #expect(items["brew:git"]?.details["installedOnRequest"] == "true")
        #expect(items["brew:abseil"]?.details["installedOnRequest"] == "false")
        #expect(items["brew:postgresql@16"]?.pinnedByProvider == true)
        #expect(items["brew:postgresql@16"]?.details["kegOnly"] == "true")
        #expect(items["brew:example-org/tools/widget"]?.details["deprecated"] == "true")
        #expect(items["brew:example-org/tools/widget"]?.details["description"]?.contains("\u{1F680}") == true)
        #expect(items["brew-cask:firefox"]?.displayName == "Mozilla Firefox")
        #expect(items["brew-cask:firefox"]?.details["usesInstallerPackage"] == nil)
        #expect(items["brew-cask:zoom"]?.details["usesInstallerPackage"] == "true")
    }

    @Test("Malformed inventory is a parse failure")
    func malformed() {
        let error = #expect(throws: MacUpError.self) {
            try HomebrewInventoryParser.parse(Data("[]".utf8), ownership: nil)
        }
        #expect(error?.kind == .parseFailed)
    }
}

@Suite("Homebrew provider")
struct HomebrewProviderTests {
    let provider = HomebrewProvider()

    private func harnessWithBrew(at directory: String = "/opt/homebrew/bin") -> ProviderHarness {
        let harness = ProviderHarness(path: "\(directory):/usr/bin:/bin")
        harness.fileSystem.addExecutable("\(directory)/brew")
        harness.runner.register("brew", ["--version"], .success("Homebrew 7.0.6-54-g86650d0\n"))
        harness.runner.register("brew", ["--prefix"], .success("/opt/homebrew\n"))
        return harness
    }

    @Test("Homebrew absent: unavailable, and nothing is run")
    func absent() async {
        let harness = ProviderHarness()
        let status = await provider.detect(context: harness.context())
        #expect(status.availability == .unavailable)
        #expect(status.error?.kind == .providerUnavailable)
        #expect(harness.requests.isEmpty)
    }

    @Test("Detection records the exact binary, version, and prefix")
    func detection() async {
        let harness = harnessWithBrew()
        let status = await provider.detect(context: harness.context())
        #expect(status.availability == .available)
        #expect(status.installation?.executable.path == "/opt/homebrew/bin/brew")
        #expect(status.installation?.version == "7.0.6-54-g86650d0")
        #expect(status.installation?.fact("prefix") == "/opt/homebrew")
        #expect(status.findings.isEmpty)
    }

    @Test("A non-standard prefix is found through PATH")
    func customPrefix() async {
        let harness = harnessWithBrew(at: "/Users/example/.homebrew/bin")
        let status = await provider.detect(context: harness.context())
        #expect(status.installation?.executable.path == "/Users/example/.homebrew/bin/brew")
        #expect(status.installation?.executable.source == .searchPath)
    }

    @Test("Two Homebrew installations produce a finding")
    func twoInstallations() async {
        let harness = harnessWithBrew()
        harness.fileSystem.addExecutable("/usr/local/bin/brew")
        let status = await provider.detect(context: harness.context())
        #expect(status.availability == .available)
        let finding = status.findings.first { $0.id == "homebrew.multipleInstallations" }
        #expect(finding?.severity == .warning)
        #expect(finding?.detail?.contains("/usr/local/bin/brew") == true)
    }

    @Test("A broken Homebrew is reported as failed, not unavailable")
    func brokenBrew() async {
        let harness = ProviderHarness()
        harness.fileSystem.addExecutable("/opt/homebrew/bin/brew")
        harness.runner.register("brew", ["--version"], .exit(1, standardError: "Error: Homebrew is broken\n"))
        harness.runner.register("brew", ["--prefix"], .exit(1))
        let status = await provider.detect(context: harness.context())
        #expect(status.availability == .failed)
        #expect(status.error?.kind == .commandFailed)
        #expect(status.error?.detail == "Error: Homebrew is broken")
    }

    @Test("An invalid configured path fails closed")
    func invalidConfiguredPath() async {
        let harness = harnessWithBrew()
        harness.settings.executablePath = "/nowhere/bin/brew"
        let status = await provider.detect(context: harness.context())
        #expect(status.availability == .failed)
        #expect(status.error?.kind == .configurationInvalid)
        #expect(harness.requests.isEmpty)
    }

    @Test("Every brew command disables auto-update and runs with an allowlisted environment")
    func environmentAndAutoUpdate() async throws {
        let harness = harnessWithBrew()
        harness.environment["HOMEBREW_GITHUB_API_TOKEN"] = "ghp_brewtoken000000000000000000000"
        harness.environment["HOMEBREW_NO_AUTO_UPDATE"] = ""
        harness.runner.register("brew", ["outdated", "--json=v2"], .success(try Fixture.text("homebrew/outdated-formula.json")))
        harness.runner.register("brew", ["info", "--json=v2", "--installed"], .success(try Fixture.text("homebrew/info-installed.json")))
        let context = try await harness.detectedContext(provider)
        _ = try await provider.outdated(context: context)
        _ = try await provider.inventory(context: context)

        #expect(harness.requests.count == 4)
        for request in harness.requests {
            #expect(request.effect == .readOnly)
            #expect(request.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
            #expect(request.environment["HOMEBREW_GITHUB_API_TOKEN"] != nil, "Homebrew's own variables pass through")
            #expect(request.environment["GITHUB_TOKEN"] == nil)
            #expect(request.environment["AWS_SECRET_ACCESS_KEY"] == nil)
            #expect(request.environment["TERM"] == nil)
            #expect(request.environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
        }
        #expect(!harness.arguments(for: "brew").contains { $0.contains("upgrade") || $0 == ["update"] })
    }

    @Test("A failed outdated check surfaces a redacted error")
    func failedCommand() async throws {
        let harness = harnessWithBrew()
        harness.runner.register("brew", ["outdated", "--json=v2"], .exit(
            1,
            standardError: "Error: Failed to download https://user:secret@example.com/api\nError: timed out\n"
        ))
        let context = try await harness.detectedContext(provider)
        let error = await #expect(throws: MacUpError.self) { try await provider.outdated(context: context) }
        #expect(error?.kind == .commandFailed)
        #expect(error?.exitStatus == 1)
        #expect(error?.detail?.contains("secret") == false)
        #expect(error?.detail?.contains("<redacted>") == true)
        #expect(error?.command == "/opt/homebrew/bin/brew outdated --json=v2")
    }

    @Test("Inventory refines candidates: installer packages and dependencies")
    func refine() throws {
        let inventory = try HomebrewInventoryParser.parse(Fixture.data("homebrew/info-installed.json"), ownership: nil).elements
        let candidates = [
            UpdateCandidate(id: try PackageID(parsing: "brew-cask:zoom"), kind: .cask, displayName: "zoom",
                            installedVersion: "6.0.0", availableVersion: "6.0.2"),
            UpdateCandidate(id: try PackageID(parsing: "brew:abseil"), kind: .formula, displayName: "abseil",
                            installedVersion: "20250127.0", availableVersion: "20260817.0"),
        ]
        let refined = provider.refine(candidates, using: inventory)
        #expect(refined[0].signals.contains(.administratorAuthorizationMayBeRequired))
        #expect(refined[0].risk.level == .high)
        #expect(refined[1].signals.contains(.mayAffectDependents))
        #expect(refined[1].notes.contains("Installed as a dependency of other formulae."))
    }

    @Test("--refresh runs brew update as a metadata refresh, and only then")
    func refresh() async throws {
        let harness = harnessWithBrew()
        harness.runner.register("brew", ["update"], .success("Already up-to-date.\n"))
        let readOnly = try await harness.detectedContext(provider)
        let denied = await #expect(throws: MacUpError.self) { try await provider.refreshMetadata(context: readOnly) }
        #expect(denied?.kind == .policyDenied)
        #expect(!harness.arguments(for: "brew").contains(["update"]))

        harness.refreshMetadata = true
        let refreshing = try await harness.detectedContext(provider)
        _ = try await provider.refreshMetadata(context: refreshing)
        let update = try #require(harness.requests.first { $0.arguments == ["update"] })
        #expect(update.effect == .metadataRefresh)
    }

    @Test("Planning is not available in the read-only engine")
    func noPlanning() async throws {
        let harness = harnessWithBrew()
        let context = try await harness.detectedContext(provider)
        let candidate = UpdateCandidate(id: try PackageID(parsing: "brew:git"), kind: .formula, displayName: "git",
                                        installedVersion: "1", availableVersion: "2")
        let error = await #expect(throws: MacUpError.self) { try await provider.makePlan(for: candidate, context: context) }
        #expect(error?.kind == .unsupported)
    }
}
