import Foundation
import Testing

@testable import MacUpCore

/// The one filter `macup history` and the History screen share.
@Suite("Narrowing history")
struct HistoryFilterTests {
    private static func entry(
        _ id: String,
        _ outcome: ExecutionResult.Outcome,
        _ verification: VerificationResult.Outcome? = nil
    ) -> HistoryEntry {
        HistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_790_000_000),
            origin: .cli,
            item: try! PackageID(parsing: id),
            versionBefore: "1.0.0",
            versionTarget: "1.0.1",
            versionAfter: verification == .verified ? "1.0.1" : nil,
            command: outcome == .skipped ? nil : "/opt/homebrew/bin/brew …",
            outcome: outcome,
            verification: verification
        )
    }

    private static let entries = [
        entry("brew:mysql", .cancelled),
        entry("npm:typescript", .failed),
        entry("brew:git", .succeeded, .verified),
        entry("brew:postgresql", .skipped),
        entry("brew-cask:firefox", .timedOut),
    ]

    private func names(_ filter: HistoryFilter) -> [String] {
        Self.entries.filter(filter.includes).map(\.subjectName)
    }

    @Test("An empty filter lets everything through")
    func emptyFilter() {
        #expect(HistoryFilter().isEmpty)
        #expect(HistoryFilter(search: "   ").isEmpty)
        #expect(names(HistoryFilter()).count == Self.entries.count)
        #expect(names(HistoryFilter(search: "  \n ")).count == Self.entries.count)
    }

    @Test("Naming items keeps their entries and no others")
    func itemFilter() throws {
        let filter = HistoryFilter(items: [try PackageID(parsing: "brew:git"), try PackageID(parsing: "brew:mysql")])
        #expect(!filter.isEmpty)
        #expect(names(filter) == ["mysql", "git"])
        // A package ID is exact: a name alone is not an item.
        #expect(names(HistoryFilter(items: [try PackageID(parsing: "brew-cask:git")])).isEmpty)
    }

    @Test("A search finds the package ID, the name, the provider, and what happened", arguments: [
        ("mysql", ["mysql"]),
        ("MYSQL", ["mysql"]),
        ("brew:git", ["git"]),
        ("npm", ["typescript"]),
        ("homebrew", ["mysql", "git", "postgresql", "firefox"]),
        ("stopped", ["mysql"]),
        ("cancelled", ["mysql"]),
        ("left alone", ["postgresql"]),
        ("timed out", ["firefox"]),
        ("failed", ["typescript"]),
        ("confirmed", ["git"]),
        ("mysql stopped", ["mysql"]),
        ("mysql failed", []),
        ("nothing like this", []),
    ])
    func search(_ text: String, _ expected: [String]) {
        #expect(names(HistoryFilter(search: text)) == expected)
    }

    @Test("Items and a search together keep only what both allow")
    func itemsAndSearch() throws {
        let mysql = try PackageID(parsing: "brew:mysql")
        #expect(names(HistoryFilter(items: [mysql], search: "stopped")) == ["mysql"])
        #expect(names(HistoryFilter(items: [mysql], search: "confirmed")).isEmpty)
    }
}
