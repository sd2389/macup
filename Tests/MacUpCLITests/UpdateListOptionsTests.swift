import Foundation
import MacUpCore
import Testing

@testable import macup

/// `--risk`, `--policy`, `--attention`, and `--sort` on `macup check` and
/// `macup plan`. The harness's Mac has three updates: brew:git (moderate),
/// brew:mysql (high), and a macOS update (high).
@Suite("Filtering and sorting in macup check and macup plan")
struct UpdateListOptionsTests {
    @Test("The options parse on both commands, and the ones that take a value repeat")
    func parsing() throws {
        let check = try #require(try MacUpCommand.parseAsRoot([
            "check", "--risk", "high", "--risk", "unknown", "--policy", "ask", "--policy", "pin",
            "--attention", "--sort", "change",
        ]) as? CheckCommand)
        #expect(check.list.riskLevels == [.high, .unknown])
        #expect(check.list.policies == [.ask, .pin])
        #expect(check.list.needsAttentionOnly)
        #expect(check.list.sort == .change)
        #expect(check.list.filter == UpdateFilter(riskLevels: [.high, .unknown], policies: [.ask, .pin], needsAttentionOnly: true))

        let plan = try #require(try MacUpCommand.parseAsRoot(["plan", "brew:git", "--sort", "name"]) as? PlanCommand)
        #expect(plan.items == ["brew:git"])
        #expect(plan.list.sort == .name)
        #expect(plan.list.isRequested)

        let plain = try #require(try MacUpCommand.parseAsRoot(["check"]) as? CheckCommand)
        #expect(!plain.list.isRequested)
    }

    @Test("A policy that is never in effect, an unknown risk, or an unknown order is a usage error")
    func rejectsValues() async throws {
        let harness = try CLIHarness()
        for arguments in [["check", "--policy", "inherit"], ["plan", "--sort", "size"], ["check", "--risk", "severe"]] {
            let run = try await harness.run(arguments)
            #expect(run.exitCode == MacUpExitCode.usage.rawValue, "\(arguments)")
        }
        #expect(harness.runner.recordedRequests.isEmpty, "nothing ran")
    }

    @Test("A filtered check says what it hides, and still counts every update")
    func filteredCheck() async throws {
        let harness = try CLIHarness()
        let run = try await harness.run(["check", "--risk", "high"])
        #expect(run.exitCode == nil)
        let output = run.standardOutput
        #expect(output.contains("Filter: high risk."))
        #expect(output.contains("brew:mysql"))
        #expect(output.contains("macos:macOS 27.2 Beta-26B5091g"))
        #expect(!output.contains("brew:git"))
        #expect(output.contains("  2 installed · 2 updates\n"), "the provider's own count is unchanged")
        #expect(output.contains("  1 update hidden by the filter\n"))
        #expect(output.contains("3 updates available (Homebrew 2, macOS 1)."))
        #expect(output.contains("1 update hidden by the filter. Run `macup check` without --risk, --policy, or --attention to see all 3."))
        #expect(!output.contains("\u{1B}"), "no ANSI when stdout is not a terminal")
    }

    @Test("A filter that hides every update never reads as a Mac with nothing to update")
    func everythingHidden() async throws {
        let harness = try CLIHarness()
        let run = try await harness.run(["check", "--attention"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("3 updates available"))
        #expect(!run.standardOutput.contains("No updates"))
        #expect(run.standardOutput.contains("3 updates hidden by the filter."))

        let json = try await harness.run(["check", "--attention", "--json"])
        let report = try JSONDecoder.iso8601.decode(CheckReport.self, from: Data(json.standardOutput.utf8))
        #expect(report.updates.isEmpty)
        #expect(report.summary.updatesAvailable == 3)
        #expect(report.filter?.hidden == 3)
        #expect(report.filter?.needsAttentionOnly == true)
    }

    @Test("check --json: no filter object without the options; with them, what was applied and left out")
    func checkJSON() async throws {
        let harness = try CLIHarness()
        let plain = try await harness.run(["check", "--json"])
        let plainObject = try #require(try JSONSerialization.jsonObject(with: Data(plain.standardOutput.utf8)) as? [String: Any])
        #expect(plainObject["filter"] == nil)

        let run = try await harness.run(["check", "--json", "--risk", "high", "--sort", "name"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        let filter = try #require(object["filter"] as? [String: Any])
        #expect(Set(filter.keys) == ["riskLevels", "policies", "needsAttentionOnly", "sort", "shown", "hidden"])
        #expect(filter["riskLevels"] as? [String] == ["high"])
        #expect((filter["policies"] as? [Any])?.isEmpty == true)
        #expect(filter["needsAttentionOnly"] as? Bool == false)
        #expect(filter["sort"] as? String == "name")
        #expect(filter["shown"] as? Int == 2)
        #expect(filter["hidden"] as? Int == 1)
        let updates = try #require(object["updates"] as? [[String: Any]])
        #expect(updates.compactMap { $0["id"] as? String } == ["macos:macOS 27.2 Beta-26B5091g", "brew:mysql"])
        let summary = try #require(object["summary"] as? [String: Any])
        #expect(summary["updatesAvailable"] as? Int == 3)
    }

    @Test("--sort alone reorders, hides nothing, and lists the updates as one table")
    func sortOnly() async throws {
        let harness = try CLIHarness()
        let output = try await harness.run(["check", "--sort", "risk"]).standardOutput
        #expect(output.contains("Sorted by risk, highest first."))
        #expect(output.contains("Updates · sorted by risk, highest first"))
        #expect(!output.contains("hidden by the filter"))
        #expect(!output.contains("The filter hides"))
        let rows = output.split(separator: "\n").filter { $0.hasPrefix("  brew:") || $0.hasPrefix("  macos:") }
        #expect(rows.map { String($0.split(separator: " ").first ?? "") } == ["brew:mysql", "macos:macOS", "brew:git"])
    }

    @Test("--save-state saves the whole check, whatever the filter shows")
    func saveStateIsUnfiltered() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        _ = try await harness.run(["check", "--save-state", "--risk", "high"])
        let saved = try Data(contentsOf: harness.stateDirectory.appending(MacUpPaths.lastCheckFileName))
        let report = try JSONDecoder.iso8601.decode(CheckReport.self, from: saved)
        #expect(report.filter == nil)
        #expect(report.updates.count == 3)
    }

    @Test("A filtered plan shows only what matches and keeps the whole plan's counts")
    func filteredPlan() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(#"{"schemaVersion": 1, "items": {"brew:git": {"policy": "auto"}, "brew:mysql": {"policy": "ignore"}}}"#)

        let run = try await harness.run(["plan", "--risk", "high"])
        #expect(run.exitCode == nil)
        let output = run.standardOutput
        #expect(output.contains("Filter: high risk."))
        #expect(!output.contains("brew:git"))
        #expect(output.contains("mysql is ignored"))
        #expect(output.contains("1 change ready to run · 1 item left alone by policy · 1 item MacUp cannot plan."))
        #expect(output.contains("1 update hidden by the filter. Run `macup plan` without --risk, --policy, or --attention to see all 3."))

        let json = try await harness.run(["plan", "--risk", "high", "--json"])
        let report = try JSONDecoder.plan.decode(PlanReport.self, from: Data(json.standardOutput.utf8))
        #expect(report.planned.isEmpty)
        #expect(report.skipped.map(\.item.rawValue) == ["brew:mysql", "macos:macOS 27.2 Beta-26B5091g"])
        #expect(report.summary.allowed == 1, "the summary is the whole plan's")
        #expect(report.filter?.shown == 2)
        #expect(report.filter?.hidden == 1)
        #expect(harness.modifyingRequests.isEmpty)
    }

    @Test("Sorted any other way than by provider, a plan's changes are one list, and plain JSON is unchanged")
    func sortedPlan() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(#"{"schemaVersion": 1, "items": {"brew:git": {"policy": "auto"}}}"#)

        let output = try await harness.run(["plan", "--sort", "risk"]).standardOutput
        #expect(output.contains("Changes · sorted by risk, highest first"))
        #expect(!output.contains("\nHomebrew\n"))
        let mysql = try #require(output.range(of: "brew:mysql"))
        let git = try #require(output.range(of: "brew:git"))
        #expect(mysql.lowerBound < git.lowerBound, "high risk first")

        let plain = try await harness.run(["plan", "--json"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(plain.standardOutput.utf8)) as? [String: Any])
        #expect(object["filter"] == nil)
    }
}
