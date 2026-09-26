import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("ReadOnlyCommandGuard")
struct ReadOnlyCommandGuardTests {
    let rules = [
        CommandRule("brew", ["outdated"], options: ["--json=v2"]),
        CommandRule("brew", ["update"], effect: .metadataRefresh),
    ]

    private func request(_ arguments: [String], effect: CommandEffect = .readOnly, executable: String = "/opt/homebrew/bin/brew") -> CommandRequest {
        CommandRequest(executable: URL(fileURLWithPath: executable), arguments: arguments, effect: effect)
    }

    @Test("Allowlisted read-only commands run")
    func allowsListedCommands() async throws {
        let fake = FakeCommandRunner()
        fake.register("brew", ["outdated", "--json=v2"], .success("{}"))
        let guarded = ReadOnlyCommandGuard(base: fake, rules: rules)
        let result = try await guarded.run(request(["outdated", "--json=v2"]))
        #expect(result.standardOutputText == "{}")
        #expect(fake.recordedRequests.count == 1)
    }

    @Test("A fresh softwareupdate scan is a metadata refresh and needs --refresh")
    func softwareUpdateScanNeedsRefresh() async throws {
        let fake = FakeCommandRunner()
        fake.register("softwareupdate", ["--list"], .success(""))
        fake.register("softwareupdate", ["--list", "--no-scan"], .success(""))
        let scan = { (effect: CommandEffect) in
            CommandRequest(executable: URL(fileURLWithPath: "/usr/sbin/softwareupdate"), arguments: ["--list"], effect: effect)
        }
        let readOnly = ReadOnlyCommandGuard(base: fake, rules: CommandAllowlist.readOnlyCheck)
        await #expect(throws: MacUpError.self) { try await readOnly.run(scan(.readOnly)) }
        await #expect(throws: MacUpError.self) { try await readOnly.run(scan(.metadataRefresh)) }
        _ = try await readOnly.run(CommandRequest(
            executable: URL(fileURLWithPath: "/usr/sbin/softwareupdate"),
            arguments: ["--list", "--no-scan"],
            effect: .readOnly
        ))
        let refreshing = ReadOnlyCommandGuard(base: fake, rules: CommandAllowlist.readOnlyCheck, allowsMetadataRefresh: true)
        _ = try await refreshing.run(scan(.metadataRefresh))
        #expect(fake.recordedRequests.map(\.arguments) == [["--list", "--no-scan"], ["--list"]])
    }

    @Test("Modifying commands are refused and never reach the runner")
    func refusesModifyingEffect() async throws {
        let fake = FakeCommandRunner()
        let guarded = ReadOnlyCommandGuard(base: fake, rules: rules, allowsMetadataRefresh: true)
        let error = await #expect(throws: MacUpError.self) {
            try await guarded.run(request(["outdated", "--json=v2"], effect: .modifying))
        }
        #expect(error?.kind == .policyDenied)
        #expect(fake.recordedRequests.isEmpty)
    }

    @Test(
        "Commands not on the allowlist are refused even when labelled read-only",
        arguments: [
            ["upgrade", "git"],
            ["outdated", "git"],
            ["outdated", "--json=v2", "--greedy"],
            ["cleanup"],
            ["outdated", "--json=v2", "$(rm -rf ~)"],
        ]
    )
    func refusesUnlistedCommands(arguments: [String]) async throws {
        let fake = FakeCommandRunner()
        let guarded = ReadOnlyCommandGuard(base: fake, rules: rules)
        let error = await #expect(throws: MacUpError.self) { try await guarded.run(request(arguments)) }
        #expect(error?.kind == .policyDenied)
        #expect(fake.recordedRequests.isEmpty)
    }

    @Test("The executable name must match the rule")
    func executableNameMustMatch() async throws {
        let fake = FakeCommandRunner()
        let guarded = ReadOnlyCommandGuard(base: fake, rules: rules)
        let error = await #expect(throws: MacUpError.self) {
            try await guarded.run(request(["outdated", "--json=v2"], executable: "/opt/homebrew/bin/not-brew"))
        }
        #expect(error?.kind == .policyDenied)
    }

    @Test("Metadata refresh requires explicit permission")
    func metadataRefreshNeedsPermission() async throws {
        let fake = FakeCommandRunner()
        fake.register("brew", ["update"], .success())
        let refresh = request(["update"], effect: .metadataRefresh)

        let denied = await #expect(throws: MacUpError.self) {
            try await ReadOnlyCommandGuard(base: fake, rules: rules).run(refresh)
        }
        #expect(denied?.kind == .policyDenied)
        #expect(fake.recordedRequests.isEmpty)

        let allowed = ReadOnlyCommandGuard(base: fake, rules: rules, allowsMetadataRefresh: true)
        #expect(try await allowed.run(refresh).succeeded)
    }

    @Test("A read-only label cannot smuggle a refresh command")
    func effectMustMatchRule() async throws {
        let fake = FakeCommandRunner()
        let guarded = ReadOnlyCommandGuard(base: fake, rules: rules, allowsMetadataRefresh: true)
        let error = await #expect(throws: MacUpError.self) { try await guarded.run(request(["update"])) }
        #expect(error?.kind == .policyDenied)
    }

    @Test("Refused commands are still recorded for the report")
    func refusedCommandsAreRecorded() async throws {
        let log = CommandLog()
        let recorder = RecordingCommandRunner(
            base: ReadOnlyCommandGuard(base: FakeCommandRunner(), rules: rules),
            log: log
        )
        _ = try? await recorder.run(request(["upgrade", "git"]))
        let records = await log.records
        #expect(records.count == 1)
        #expect(records.first?.outcome == .refused)
        #expect(records.first?.command == "/opt/homebrew/bin/brew upgrade git")
    }
}
