import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Homebrew dependents")
struct HomebrewDependentsTests {
    let provider = HomebrewProvider()
    let openssl = try! PackageID(.brew, "openssl@3")

    /// A harness whose runner allows what a lookup allows: the check's rules
    /// plus the one-item `brew uses` rules.
    private func harness(formulae: FakeCommandRunner.Response, casks: FakeCommandRunner.Response = .success()) -> ProviderHarness {
        let harness = ProviderHarness()
        harness.fileSystem.addExecutable("/opt/homebrew/bin/brew")
        harness.runner.register("brew", ["--version"], .success("Homebrew 7.0.6\n"))
        harness.runner.register("brew", ["--prefix"], .success("/opt/homebrew\n"))
        harness.runner.register("brew", HomebrewProvider.dependentsArguments(of: "openssl@3", casks: false), formulae)
        harness.runner.register("brew", HomebrewProvider.dependentsArguments(of: "openssl@3", casks: true), casks)
        return harness
    }

    private func lookupContext(_ harness: ProviderHarness) async throws -> ProviderContext {
        var context = try await harness.detectedContext(provider)
        context.runner = ReadOnlyCommandGuard(
            base: harness.runner,
            rules: CommandAllowlist.readOnlyCheck + CommandAllowlist.dependentsLookup
        )
        return context
    }

    @Test("Formulae and casks are asked for separately and come back as package IDs")
    func listsDependents() async throws {
        let harness = harness(
            formulae: .success(try Fixture.text("homebrew/uses-installed-formula.txt")),
            casks: .success("wireshark-app\n")
        )
        let listing = try await provider.dependents(of: openssl, context: try await lookupContext(harness))
        #expect(listing.elements.map(\.rawValue) == [
            "brew-cask:wireshark-app",
            "brew:aws-c-auth", "brew:aws-c-cal", "brew:awscli", "brew:ffmpeg", "brew:krb5", "brew:libssh2",
            "brew:mysql", "brew:postgresql@16", "brew:python@3.14", "brew:redis",
        ])
        #expect(!listing.isIncomplete)
        #expect(harness.arguments(for: "brew").filter { $0.first == "uses" }.sorted { $0[2] < $1[2] } == [
            ["uses", "--installed", "--cask", "openssl@3"],
            ["uses", "--installed", "--formula", "openssl@3"],
        ])
        #expect(harness.requests.allSatisfy { $0.effect == .readOnly })
    }

    @Test("Nothing depends on it: an empty answer with no warning")
    func nothing() async throws {
        let listing = try await provider.dependents(of: openssl, context: try await lookupContext(harness(formulae: .success())))
        #expect(listing.elements.isEmpty)
        #expect(!listing.isIncomplete)
    }

    @Test("Columns, which Homebrew prints to a terminal, read the same as one name per line")
    func columns() async throws {
        let listing = try await provider.dependents(
            of: openssl,
            context: try await lookupContext(harness(formulae: .success("awscli   ffmpeg\nkrb5\n")))
        )
        #expect(listing.elements.map(\.name) == ["awscli", "ffmpeg", "krb5"])
    }

    @Test("An empty answer that came with a warning is not taken to mean nothing depends on it")
    func warningIsNotNothing() async throws {
        let warning = try Fixture.text("homebrew/uses-unknown-formula.stderr.txt")
        let context = try await lookupContext(harness(formulae: .success("", standardError: warning)))
        let error = await #expect(throws: MacUpError.self) { try await provider.dependents(of: openssl, context: context) }
        #expect(error?.kind == .parseFailed)
        #expect(error?.message.contains("printed a warning instead") == true)
        #expect(error?.detail?.contains("No available formula") == true)
    }

    @Test("A failed `brew uses` is an error, not an empty list")
    func failure() async throws {
        let context = try await lookupContext(harness(formulae: .exit(1, standardError: "Error: something broke\n")))
        let error = await #expect(throws: MacUpError.self) { try await provider.dependents(of: openssl, context: context) }
        #expect(error?.kind == .commandFailed)
        #expect(error?.exitStatus == 1)
    }

    @Test("A name MacUp cannot read is skipped, said so, and makes the list incomplete")
    func unreadableName() async throws {
        let listing = try await provider.dependents(
            of: openssl,
            context: try await lookupContext(harness(formulae: .success("awscli\n-evil\n")))
        )
        #expect(listing.elements.map(\.name) == ["awscli"])
        #expect(listing.isIncomplete)
        #expect(listing.findings.map(\.id) == ["homebrew.unusableName"])
    }

    @Test("Only formulae can be asked about")
    func onlyFormulae() async throws {
        #expect(provider.canListDependents(of: openssl))
        let cask = try PackageID(.brewCask, "firefox")
        #expect(!provider.canListDependents(of: cask))
        let harness = harness(formulae: .success())
        let error = await #expect(throws: MacUpError.self) {
            try await provider.dependents(of: cask, context: try await lookupContext(harness))
        }
        #expect(error?.kind == .unsupported)
        #expect(!harness.requests.contains { $0.arguments.first == "uses" })
        #expect(!NpmProvider().canListDependents(of: try PackageID(.npm, "typescript")))
    }
}

@Suite("Read-only rules that name an item")
struct DependentsRuleTests {
    private func request(_ arguments: [String]) -> CommandRequest {
        CommandRequest(executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), arguments: arguments, effect: .readOnly)
    }

    @Test("No rule a check uses accepts a positional, so a check never names a package")
    func checkRulesNameNothing() {
        #expect(CommandAllowlist.readOnlyCheck.allSatisfy { $0.positionalCount == 0 })
        #expect(!CommandAllowlist.readOnlyCheck.contains { $0.matches(request(["uses", "--installed", "--formula", "mysql"])) })
    }

    @Test("A check's guard refuses `brew uses`, even labelled read-only")
    func checkGuardRefusesUses() async throws {
        let fake = FakeCommandRunner()
        fake.register("brew", ["uses", "--installed", "--formula", "mysql"], .success())
        let guarded = ReadOnlyCommandGuard(base: fake, rules: CommandAllowlist.readOnlyCheck)
        let error = await #expect(throws: MacUpError.self) {
            try await guarded.run(request(["uses", "--installed", "--formula", "mysql"]))
        }
        #expect(error?.kind == .policyDenied)
        #expect(fake.recordedRequests.isEmpty)
    }

    @Test(
        "The lookup rules take exactly one formula name, checked like a modifying command's",
        arguments: [
            (["uses", "--installed", "--formula", "mysql"], true),
            (["uses", "--installed", "--cask", "openssl@3"], true),
            (["uses", "--installed", "--formula", "user/tap/tool"], true),
            (["uses", "--installed", "--formula"], false),
            (["uses", "--installed", "--formula", "mysql", "git"], false),
            (["uses", "--installed", "--formula", "--recursive"], false),
            (["uses", "--installed", "--formula", "--eval-all", "mysql"], false),
            (["uses", "--formula", "mysql"], false),
            (["uses", "--installed", "--formula", "my\u{1B}[2Jsql"], false),
            (["uses", "--installed", "--formula", " mysql"], false),
        ]
    )
    func lookupRules(arguments: [String], allowed: Bool) {
        #expect(CommandAllowlist.dependentsLookup.contains { $0.matches(request(arguments)) } == allowed)
    }

    @Test("The services rule matches only the exact listing")
    func servicesRule() {
        let rules = CommandAllowlist.readOnlyCheck
        #expect(rules.contains { $0.matches(request(["services", "list", "--json"])) })
        for arguments in [["services", "list"], ["services", "restart", "mysql"], ["services", "start", "--all"], ["services", "list", "--json", "mysql"], ["services", "cleanup"]] {
            #expect(!rules.contains { $0.matches(request(arguments)) }, "\(arguments)")
        }
    }
}
