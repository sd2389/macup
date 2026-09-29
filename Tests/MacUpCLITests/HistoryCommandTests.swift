import Foundation
import MacUpCore
import Testing

@testable import macup

@Suite("macup history")
struct HistoryCommandTests {
    private static let noon = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(
        _ id: String,
        at offset: TimeInterval,
        outcome: ExecutionResult.Outcome = .succeeded,
        verification: VerificationResult.Outcome? = .verified,
        before: String? = "1.0.0",
        after: String? = "1.1.0",
        origin: ExecutionOrigin = .cli,
        skipReason: String? = nil
    ) throws -> HistoryEntry {
        HistoryEntry(
            timestamp: Self.noon.addingTimeInterval(offset),
            origin: origin,
            item: try PackageID(parsing: id),
            versionBefore: before,
            versionTarget: after,
            versionAfter: outcome == .succeeded ? after : nil,
            command: "/opt/homebrew/bin/brew upgrade --formula --yes \(id)",
            outcome: outcome,
            verification: verification,
            skipReason: skipReason,
            durationSeconds: 3.5
        )
    }

    @Test("With no history, MacUp says so and where it would be written")
    func emptyHistory() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["history"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("No history yet."))
        #expect(run.standardOutput.contains("history.jsonl"))
        #expect(run.standardOutput.contains("MacUp has not changed anything on this Mac."))
    }

    @Test("History is newest first, with versions, outcome, verification and origin")
    func newestFirst() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry("brew:git", at: 0))
        try harness.historyStore.append(entry("npm:@scope/name", at: 60, origin: .gui))

        let run = try await harness.run(["history"])
        #expect(run.exitCode == nil)
        let git = try #require(run.standardOutput.range(of: "brew:git"))
        let npm = try #require(run.standardOutput.range(of: "npm:@scope/name"))
        #expect(npm.lowerBound < git.lowerBound)
        #expect(run.standardOutput.contains("1.0.0 → 1.1.0"))
        #expect(run.standardOutput.contains("Upgraded and confirmed"))
        #expect(run.standardOutput.contains("started from the command line"))
        #expect(run.standardOutput.contains("started from the MacUp app"))
        #expect(run.standardOutput.contains("via Homebrew"))
        #expect(run.standardOutput.contains("via npm"))
        #expect(run.standardOutput.contains("2 entries shown."))
    }

    @Test("An attempt MacUp could not confirm does not read as done")
    func unverifiedAttempt() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry("brew:git", at: 0, verification: .targetNotReached))

        let run = try await harness.run(["history"])
        #expect(run.standardOutput.contains("Ran without an error, but git is not at the new version"))
        #expect(!run.standardOutput.contains("confirmed"))
    }

    @Test("A skipped attempt shows the reason MacUp left it alone")
    func skipReasonIsShown() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry(
            "brew:postgresql",
            at: 0,
            outcome: .skipped,
            verification: nil,
            skipReason: "postgresql is ignored (a rule you set for this item)."
        ))

        let run = try await harness.run(["history"])
        #expect(run.standardOutput.contains("Left alone"))
        #expect(run.standardOutput.contains("Why: postgresql is ignored"))
    }

    @Test("A line MacUp cannot read is reported, not silently dropped")
    func unreadableLinesAreReported() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry("brew:git", at: 0))
        let file = harness.stateDirectory.appending("history.jsonl")
        try (String(contentsOf: file, encoding: .utf8) + "{ not json at all\n").write(to: file, atomically: true, encoding: .utf8)

        let run = try await harness.run(["history"])
        #expect(run.standardOutput.contains("brew:git"))
        #expect(run.standardOutput.contains("One history entry could not be read"))
        #expect(run.standardOutput.contains("1 entry shown."))
    }

    @Test("--limit caps what is shown and says there may be more")
    func limitCapsTheList() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        for index in 0..<5 {
            try harness.historyStore.append(entry("brew:git", at: Double(index) * 60))
        }

        let run = try await harness.run(["history", "--limit", "2"])
        #expect(run.standardOutput.contains("2 entries shown."))
        #expect(run.standardOutput.contains("macup history --limit 4"))
    }

    @Test("A limit below one is a usage error")
    func limitMustBePositive() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["history", "--limit", "0"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains("--limit must be at least 1."))
    }

    @Test("--verbose adds the command MacUp ran; how long an attempt took is always shown")
    func verboseShowsCommands() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry("brew:git", at: 0))

        let plain = try await harness.run(["history"])
        #expect(!plain.standardOutput.contains("Ran: "))
        #expect(plain.standardOutput.contains("ran for 4 seconds"))

        let run = try await harness.run(["history", "--verbose"])
        #expect(run.standardOutput.contains("Ran: /opt/homebrew/bin/brew upgrade --formula --yes brew:git"))
    }

    @Test("history --json decodes back into history entries, with its schema version")
    func jsonDecodes() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry("brew:git", at: 0))

        let run = try await harness.run(["history", "--json"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["kind"] as? String == "history")
        #expect(object["unreadableLines"] as? Int == 0)

        let entries = try JSONDecoder.plan.decode(
            [HistoryEntry].self,
            from: try JSONSerialization.data(withJSONObject: try #require(object["entries"]))
        )
        #expect(entries.count == 1)
        #expect(entries[0].item.rawValue == "brew:git")
        #expect(entries[0].schemaVersion == HistoryEntry.schemaVersion)
    }

    @Test("An update MacUp just ran shows up in history")
    func recordsAnActualUpdate() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")
        _ = try await harness.run(["update", "brew:git", "--yes"])

        let run = try await harness.run(["history"])
        #expect(run.standardOutput.contains("brew:git"))
        #expect(run.standardOutput.contains("2.43.0 → 2.44.0 · now 2.44.0"))
        #expect(run.standardOutput.contains("Upgraded and confirmed"))
    }

    // MARK: What an unsuccessful attempt left

    @Test("A failed update MacUp just ran says what it left, read back from the provider")
    func recordsWhatAFailureLeft() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        // Homebrew fails, and reading it back afterwards finds git unmoved.
        harness.allowBrewUpgrade("git", readingBack: "2.43.0", .exit(1, standardError: "Error: git 2.44.0 is not bottled\n"))
        let update = try await harness.run(["update", "brew:git", "--yes"])
        #expect(update.exitCode == MacUpExitCode.updateFailed.rawValue)
        // The run's own report says what the read-back found, rather than
        // assuming the item is as it was.
        #expect(update.standardOutput.contains("git is 2.43.0; the plan proposed 2.44.0."))
        #expect(update.standardOutput.contains("MacUp read each failed item back afterwards"))

        let run = try await harness.run(["history", "brew:git"])
        #expect(run.standardOutput.contains("Failed — git was not upgraded"))
        #expect(run.standardOutput.contains("2.43.0 → 2.44.0 · now 2.43.0"))
        #expect(run.standardOutput.contains("Details: "), "the provider's error is detail under the headline")

        let entry = try #require(try harness.historyStore.load().first)
        #expect(entry.outcome == .failed)
        #expect(entry.verification == .targetNotReached)
        #expect(entry.versionAfter == "2.43.0")
    }

    @Test("A line written before MacUp read items back renders with one headline and no guess about afterwards")
    func earlierLinesRenderWell() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        // A real entry from an upgrade that was stopped part-way, as an
        // earlier MacUp wrote it, anonymized.
        let line = #"{"command":"/Users/example/.homebrew/bin/brew upgrade --formula --yes mysql","durationSeconds":94.8895890712738,"errorSummary":"The command was cancelled.","id":"8E144797-A201-47E8-A709-B3B4615804FC","item":"brew:mysql","origin":"gui","outcome":"cancelled","schemaVersion":1,"timestamp":"2026-09-29T14:41:43.831Z","versionBefore":"9.7.1","versionTarget":"26.7.0_2"}"#
        try (line + "\n").write(to: harness.stateDirectory.appending("history.jsonl"), atomically: true, encoding: .utf8)

        let run = try await harness.run(["history"])
        #expect(run.exitCode == nil)
        let output = run.standardOutput
        #expect(output.contains("brew:mysql"))
        #expect(output.contains("Stopped before the upgrade finished"))
        #expect(output.contains("9.7.1 → 26.7.0_2"))
        #expect(!output.contains("now "), "nothing was read back, so nothing is said about afterwards")
        #expect(!output.contains("was not upgraded"))
        #expect(output.contains("via Homebrew · started from the MacUp app · ran for 1 minute, 35 seconds"))
        #expect(output.contains("Details: The command was cancelled."))
        #expect(!output.contains("One history entry could not be read"))
        // The headline comes before the error text, and appears once.
        let headline = try #require(output.range(of: "Stopped before the upgrade finished"))
        let details = try #require(output.range(of: "The command was cancelled."))
        #expect(headline.lowerBound < details.lowerBound)
        #expect(output.components(separatedBy: "Stopped").count == 2)
    }

    // MARK: One item, or a search

    @Test("Naming a package ID shows only that item's entries")
    func filtersToOneItem() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry("brew:git", at: 0))
        try harness.historyStore.append(entry("brew:mysql", at: 30, outcome: .cancelled, verification: nil))
        try harness.historyStore.append(entry("npm:@scope/name", at: 60))

        let run = try await harness.run(["history", "brew:mysql"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("MacUp history for brew:mysql"))
        #expect(run.standardOutput.contains("brew:mysql"))
        #expect(!run.standardOutput.contains("brew:git"))
        #expect(!run.standardOutput.contains("npm:@scope/name"))
        #expect(run.standardOutput.contains("1 entry shown."))
    }

    @Test("A limit counts the named item's entries, and the hint to look further keeps the item")
    func limitWithAnItem() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        for index in 0..<3 {
            try harness.historyStore.append(entry("brew:git", at: Double(index)))
        }
        for index in 3..<10 {
            try harness.historyStore.append(entry("brew:wget", at: Double(index)))
        }

        let run = try await harness.run(["history", "brew:git", "--limit", "2"])
        #expect(run.standardOutput.contains("2 entries shown."))
        #expect(!run.standardOutput.contains("brew:wget"))
        #expect(run.standardOutput.contains("`macup history brew:git --limit 4`"))
    }

    @Test("--search keeps the entries whose item, provider, or outcome match every word")
    func searchNarrowsTheList() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry("brew:git", at: 0))
        try harness.historyStore.append(entry("brew:mysql", at: 30, outcome: .cancelled, verification: nil))
        try harness.historyStore.append(entry("npm:@scope/name", at: 60, outcome: .failed, verification: nil))

        let stopped = try await harness.run(["history", "--search", "stopped"])
        #expect(stopped.standardOutput.contains("matching \"stopped\""))
        #expect(stopped.standardOutput.contains("brew:mysql"))
        #expect(!stopped.standardOutput.contains("brew:git"))
        #expect(!stopped.standardOutput.contains("npm:@scope/name"))

        let npm = try await harness.run(["history", "--search", "NPM failed"])
        #expect(npm.standardOutput.contains("npm:@scope/name"))
        #expect(npm.standardOutput.contains("1 entry shown."))

        let nothing = try await harness.run(["history", "--search", "no such thing"])
        #expect(nothing.exitCode == nil)
        #expect(nothing.standardOutput.contains("No history entry matches \"no such thing\"."))
    }

    @Test("An item with no history says so, rather than looking like an empty log")
    func itemWithNoHistory() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry("brew:git", at: 0))

        let run = try await harness.run(["history", "npm:typescript"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("No history for npm:typescript."))
        #expect(!run.standardOutput.contains("No history yet."))
    }

    @Test("Something that is not a package ID stops the command before it reads anything")
    func rejectsMalformedPackageID() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["history", "mysql"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains("is not a package ID"))
    }

    @Test("history <package-id> --json lists that item's entries and says what was asked for")
    func jsonForOneItem() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry("brew:git", at: 0))
        var stopped = try entry("brew:mysql", at: 30, outcome: .cancelled, verification: .targetNotReached, after: "26.7.0_2")
        stopped.versionAfter = "9.7.1"
        stopped.stateAfter = "No version of mysql is linked, so its commands are not on your PATH."
        try harness.historyStore.append(stopped)

        let run = try await harness.run(["history", "brew:mysql", "--json"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any])
        #expect(object["kind"] as? String == "history")
        #expect(object["items"] as? [String] == ["brew:mysql"])
        #expect(object["search"] == nil)
        let entries = try JSONDecoder.plan.decode(
            [HistoryEntry].self,
            from: try JSONSerialization.data(withJSONObject: try #require(object["entries"]))
        )
        #expect(entries.map(\.item.rawValue) == ["brew:mysql"])
        #expect(entries.first?.versionAfter == "9.7.1")
        #expect(entries.first?.stateAfter == "No version of mysql is linked, so its commands are not on your PATH.")

        let everything = try await harness.run(["history", "--json"])
        let unfiltered = try #require(JSONSerialization.jsonObject(with: Data(everything.standardOutput.utf8)) as? [String: Any])
        #expect(unfiltered["items"] as? [String] == [])
    }

    @Test("History output carries no ANSI escapes when stdout is not a terminal")
    func noStylingWithoutATerminal() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry("brew:git", at: 0))

        let run = try await harness.run(["history", "--verbose"])
        #expect(!run.standardOutput.contains("\u{1B}["))
    }
}
