import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// The words both History surfaces use. Every combination of what happened to
/// an attempt and what MacUp read back afterwards gets exactly one headline,
/// and none of them claims more than the entry holds.
@Suite("What history says happened")
struct HistoryHeadlineTests {
    private static let noon = Date(timeIntervalSince1970: 1_790_000_000)

    private static func entry(
        _ outcome: ExecutionResult.Outcome,
        _ verification: VerificationResult.Outcome? = nil,
        before: String? = "9.7.1",
        after: String? = nil,
        command: String? = "/opt/homebrew/bin/brew upgrade --formula --yes mysql",
        origin: ExecutionOrigin = .gui,
        duration: Double? = 94.9
    ) -> HistoryEntry {
        HistoryEntry(
            timestamp: noon,
            origin: origin,
            item: try! PackageID(parsing: "brew:mysql"),
            versionBefore: before,
            versionTarget: "26.7.0_2",
            versionAfter: after,
            command: outcome == .skipped ? nil : command,
            outcome: outcome,
            verification: verification,
            skipReason: outcome == .skipped ? "mysql is ignored (a rule you set for this item)." : nil,
            durationSeconds: outcome == .skipped ? nil : duration
        )
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let entry: HistoryEntry
        let kind: HistoryHeadline.Kind
        let text: String

        init(_ entry: HistoryEntry, _ kind: HistoryHeadline.Kind, _ text: String) {
            self.entry = entry
            self.kind = kind
            self.text = text
        }

        var testDescription: String {
            "\(entry.outcome.rawValue), read back \(entry.verification?.rawValue ?? "nothing"), after \(entry.versionAfter ?? "unknown")"
        }
    }

    static let cases: [Case] = [
        // The command succeeded.
        Case(entry(.succeeded, .verified, after: "26.7.0_2"), .confirmed, "Updated and confirmed"),
        Case(entry(.succeeded, .targetNotReached, after: "9.7.1"), .targetNotReached, "Ran without an error, but mysql was not updated"),
        Case(entry(.succeeded, .targetNotReached, after: "26.6.0"), .targetNotReached, "Ran without an error, but mysql is not at the new version"),
        Case(entry(.succeeded, .failed), .unconfirmed, "Updated, but MacUp could not confirm the new version"),
        Case(entry(.succeeded, .notPerformed), .unconfirmed, "Updated, but MacUp could not confirm the new version"),
        Case(entry(.succeeded), .unconfirmed, "Updated, but MacUp could not confirm the new version"),
        // It failed.
        Case(entry(.failed, .verified, after: "26.7.0_2"), .failed, "Failed, but mysql is at the new version"),
        Case(entry(.failed, .targetNotReached, after: "9.7.1"), .failed, "Failed — mysql was not updated"),
        Case(entry(.failed, .targetNotReached, after: "26.6.0"), .failed, "Failed — mysql is not at the new version"),
        Case(entry(.failed, .targetNotReached, before: nil, after: "9.7.1"), .failed, "Failed — mysql is not at the new version"),
        Case(entry(.failed, .failed), .failed, "Failed — MacUp could not read the version back"),
        Case(entry(.failed, .notPerformed), .failed, "Failed — MacUp changed nothing further"),
        Case(entry(.failed), .failed, "Failed — MacUp changed nothing further"),
        // It ran past its time limit.
        Case(entry(.timedOut, .verified, after: "26.7.0_2"), .timedOut, "Timed out, but mysql is at the new version"),
        Case(entry(.timedOut, .targetNotReached, after: "9.7.1"), .timedOut, "Timed out — mysql was not updated"),
        Case(entry(.timedOut, .targetNotReached, after: "26.6.0"), .timedOut, "Timed out — mysql is not at the new version"),
        Case(entry(.timedOut, .failed), .timedOut, "Timed out — MacUp could not read the version back"),
        Case(entry(.timedOut, .notPerformed), .timedOut, "Timed out before the update finished"),
        Case(entry(.timedOut), .timedOut, "Timed out before the update finished"),
        // It was stopped.
        Case(entry(.cancelled, .verified, after: "26.7.0_2"), .stopped, "Stopped, but mysql is at the new version"),
        Case(entry(.cancelled, .targetNotReached, after: "9.7.1"), .stopped, "Stopped — mysql was not updated"),
        Case(entry(.cancelled, .targetNotReached, after: "26.6.0"), .stopped, "Stopped — mysql is not at the new version"),
        Case(entry(.cancelled, .failed), .stopped, "Stopped — MacUp could not read the version back"),
        Case(entry(.cancelled, .notPerformed), .stopped, "Stopped before the update finished"),
        Case(entry(.cancelled), .stopped, "Stopped before the update finished"),
        Case(entry(.cancelled, command: nil), .stopped, "Stopped before anything ran"),
        // MacUp left it alone. Nothing was read back for a skip, but the
        // headline would not change if something were.
        Case(entry(.skipped), .leftAlone, "Left alone"),
        Case(entry(.skipped, .verified, after: "26.7.0_2"), .leftAlone, "Left alone"),
        Case(entry(.skipped, .targetNotReached, after: "9.7.1"), .leftAlone, "Left alone"),
        Case(entry(.skipped, .failed), .leftAlone, "Left alone"),
        Case(entry(.skipped, .notPerformed), .leftAlone, "Left alone"),
    ]

    @Test("Every outcome and read-back gets exactly one headline, in plain words", arguments: cases)
    func headline(_ expected: Case) {
        let headline = expected.entry.headline
        #expect(headline.kind == expected.kind)
        #expect(headline.text == expected.text)
    }

    @Test("A version that differs only in spelling still counts as the one it started from")
    func spellingOfTheVersionDoesNotMatter() {
        let entry = Self.entry(.failed, .targetNotReached, before: "v9.7.1", after: "9.7.1")
        #expect(entry.headline.text == "Failed — mysql was not updated")
    }

    @Test("Only a confirmed update gets the checkmark, and a deliberate stop is never shown as an error")
    func symbolsRepeatTheWords() {
        for kind in HistoryHeadline.Kind.allCases {
            let headline = Self.cases.first { $0.kind == kind }!.entry.headline
            #expect((headline.symbolName == "checkmark.circle") == (kind == .confirmed))
            #expect((headline.tone == .good) == (kind == .confirmed))
        }
        let stopped = Self.entry(.cancelled).headline
        #expect(stopped.symbolName == "stop.circle")
        #expect(stopped.tone == .neutral)
        #expect(Self.entry(.skipped).headline.tone == .neutral)
        #expect(Self.entry(.failed).headline.tone == .problem)
        #expect(Self.entry(.timedOut).headline.tone == .problem)
        #expect(Self.entry(.succeeded).headline.tone == .caution)
        #expect(Self.entry(.succeeded, .targetNotReached, after: "9.7.1").headline.tone == .caution)
    }

    @Test("Versions read before, target, and — only when MacUp looked — what the item is now")
    func versionSummary() {
        #expect(Self.entry(.cancelled, .targetNotReached, after: "9.7.1").versionSummary == "9.7.1 → 26.7.0_2 · now 9.7.1")
        #expect(Self.entry(.cancelled).versionSummary == "9.7.1 → 26.7.0_2")
        #expect(Self.entry(.skipped).versionSummary == "9.7.1 → 26.7.0_2")
        #expect(Self.entry(.failed, before: nil).versionSummary == "unknown → 26.7.0_2")
    }

    @Test("The facts about an attempt each say what they are")
    func circumstancesAreLabelled() {
        #expect(Self.entry(.cancelled).circumstances == [
            "via Homebrew", "started from the MacUp app", "ran for 1 minute, 35 seconds",
        ])
        #expect(Self.entry(.succeeded, .verified, origin: .cli, duration: 12.4).circumstances == [
            "via Homebrew", "started from the command line", "ran for 12 seconds",
        ])
        #expect(Self.entry(.failed, origin: .scheduled, duration: nil).circumstances == [
            "via Homebrew", "started on a schedule",
        ])
        // Nothing ran for a skip, so nothing started and nothing took time.
        #expect(Self.entry(.skipped, origin: .cli).circumstances == ["via Homebrew", "from the command line"])
    }

    @Test("Durations read the way a person would say them", arguments: [
        (0.2, "less than a second"),
        (1.0, "1 second"),
        (3.5, "4 seconds"),
        (12.4, "12 seconds"),
        (60.0, "1 minute"),
        (94.8895890712738, "1 minute, 35 seconds"),
        (3600.4, "1 hour"),
        (3661.0, "1 hour, 1 minute"),
        (16_200.0, "4 hours, 30 minutes"),
    ] as [(Double, String)])
    func durations(_ seconds: Double, _ words: String) {
        #expect(HistoryEntry.describe(duration: seconds) == words)
    }

    @Test("Lines written before MacUp read items back say what happened and nothing about afterwards")
    func linesFromBeforeReadBack() throws {
        let decoder = HistoryStore.decoder()
        let entries = try Fixture.text("history/before-read-back.jsonl")
            .split(separator: "\n")
            .map { try decoder.decode(HistoryEntry.self, from: Data($0.utf8)) }

        #expect(entries.map(\.headline.text) == [
            "Updated and confirmed",
            "Left alone",
            "Failed — MacUp changed nothing further",
            "Timed out before the update finished",
            "Stopped before the update finished",
        ])
        #expect(entries.allSatisfy { $0.stateAfter == nil })
        for entry in entries where entry.outcome != .succeeded {
            #expect(!entry.versionSummary.contains("now"), "\(entry.item) recorded nothing afterwards")
            #expect(!entry.headline.text.contains("was not updated"), "\(entry.item) would be a guess")
        }

        // The stopped mysql upgrade that prompted all of this.
        let mysql = try #require(entries.last)
        #expect(mysql.item.rawValue == "brew:mysql")
        #expect(mysql.headline.kind == .stopped)
        #expect(mysql.headline.symbolName == "stop.circle")
        #expect(mysql.versionSummary == "9.7.1 → 26.7.0_2")
        #expect(mysql.circumstances == ["via Homebrew", "started from the MacUp app", "ran for 1 minute, 35 seconds"])
        #expect(mysql.errorSummary == "The command was cancelled.")
    }
}
