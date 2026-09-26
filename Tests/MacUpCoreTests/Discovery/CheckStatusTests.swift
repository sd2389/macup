import Foundation
import Testing

@testable import MacUpCore

@Suite("Check status")
struct CheckStatusTests {
    private func report(
        providers: [ProviderReport],
        updates: Int = 0,
        cancelled: Bool = false
    ) throws -> CheckReport {
        let id = try PackageID(.brew, "git")
        let candidates = (0..<updates).map { _ in
            UpdateCandidate(id: id, kind: .formula, displayName: "git", installedVersion: InstalledVersion("1.0"), availableVersion: AvailableVersion("1.1"))
        }
        return CheckReport(
            mode: .readOnly,
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1),
            cancelled: cancelled,
            configuration: ConfigurationSummary(LoadedConfiguration(configuration: .defaults, source: .defaults, path: "/Users/example/.config/macup/config.json")),
            providers: providers,
            updates: candidates,
            commands: []
        )
    }

    private func provider(
        _ id: ProviderID,
        errors: [ProviderOperationError] = [],
        unreadable: Int = 0,
        incomplete: Bool = false
    ) -> ProviderReport {
        ProviderReport(
            provider: id,
            displayName: id.displayName,
            availability: .available,
            capabilities: [.detect, .outdated],
            updateCount: errors.isEmpty ? 0 : nil,
            unreadableUpdates: unreadable,
            resultsIncomplete: incomplete || unreadable > 0,
            errors: errors
        )
    }

    @Test("Before and during a check")
    func notCheckedAndChecking() {
        #expect(CheckStatus(report: nil, isChecking: false) == .notChecked)
        #expect(CheckStatus(report: nil, isChecking: true) == .checking)
        #expect(CheckStatus(report: nil, isChecking: false).symbolName != "checkmark.circle")
    }

    @Test("A complete check is up to date or has updates")
    func complete() throws {
        let clean = CheckStatus(report: try report(providers: [provider(.homebrew)]), isChecking: false)
        #expect(clean == .upToDate)
        #expect(clean.headline == "Everything is up to date")
        #expect(clean.symbolName == "checkmark.circle")
        #expect(CheckStatus(report: try report(providers: [provider(.homebrew)], updates: 2), isChecking: false) == .updatesAvailable(2))
    }

    @Test("A failed, cancelled, or partial check is never \"up to date\"")
    func incomplete() throws {
        let failed = ProviderOperationError(operation: .outdated, error: MacUpError(.commandFailed, "npm could not reach the package registry."))
        let cases: [(CheckReport, String?, String)] = [
            (try report(providers: [provider(.homebrew), provider(.npm, errors: [failed])]), nil, "npm could not be checked."),
            (try report(providers: [provider(.homebrew)], cancelled: true), nil, "The last check was cancelled before it finished."),
            (try report(providers: [provider(.macos, unreadable: 1)]), nil, "macOS listed 1 update MacUp could not read."),
            (try report(providers: [provider(.mise, incomplete: true)]), nil, "mise may be missing results."),
            (try report(providers: [provider(.homebrew)]), "timed out", "Your shell environment could not be read, so some tools may not have been found."),
        ]
        for (report, environmentProblem, reason) in cases {
            let status = CheckStatus(report: report, isChecking: false, environmentProblem: environmentProblem)
            #expect(status.headline == "Check incomplete")
            #expect(status.symbolName == "exclamationmark.triangle")
            #expect(status.reasons.contains(reason), "\(status.reasons)")
        }
        let partial = CheckStatus(report: try report(providers: [provider(.homebrew), provider(.npm, errors: [failed])], updates: 3), isChecking: false)
        #expect(partial.headline == "3 updates found; check incomplete")
    }
}
