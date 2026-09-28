import Foundation

/// Reports providers whose listing or parsing did not finish, so an incomplete
/// answer is never shown as "up to date" (CLAUDE.md §13, §23).
///
/// Detection problems belong to ``ProviderAvailabilityCheck``; this check is
/// about a provider that ran and then could not be read.
public struct ProviderResultsCheck: DiagnosticCheck {
    public let id = "provider.results"
    public let title = "Whether every provider's results could be read"

    public init() {}

    public func run(_ input: DiagnosticInput) async -> [DiagnosticFinding] {
        var findings: [DiagnosticFinding] = []
        for report in input.report.providers {
            findings += report.errors
                .filter { $0.operation != .detect }
                .map { operationFailed($0, report: report, input: input) }
            if let finding = incomplete(report, input: input) { findings.append(finding) }
        }
        return findings
    }

    private func operationFailed(
        _ failure: ProviderOperationError,
        report: ProviderReport,
        input: DiagnosticInput
    ) -> DiagnosticFinding {
        let detail = [failure.error.message, failure.error.detail]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return DiagnosticFinding(
            id: "provider.operationFailed",
            severity: .error,
            provider: report.provider,
            title: "MacUp could not \(Self.describe(failure.operation)) \(report.displayName)",
            detail: input.display(detail),
            recommendation: failure.error.kind == .parseFailed
                ? "MacUp will not guess at output it cannot read, so it reports nothing for \(report.displayName) "
                    + "rather than a partial list. This usually means the provider's output changed."
                : failure.error.recoverySuggestion
                    ?? "MacUp reports no updates for \(report.displayName) while this fails."
        )
    }

    /// The provider finished but left something out. Providers normally
    /// explain that themselves; when nothing did, the gap is reported here so
    /// it cannot pass unmentioned.
    private func incomplete(_ report: ProviderReport, input: DiagnosticInput) -> DiagnosticFinding? {
        guard report.availability == .available, !report.hasErrors, report.resultsIncomplete else { return nil }
        guard report.findings.isEmpty else { return nil }
        let skipped = report.unreadableUpdates
        return DiagnosticFinding(
            id: "provider.resultsIncomplete",
            severity: .warning,
            provider: report.provider,
            title: "\(report.displayName)'s update list is missing something",
            detail: skipped > 0
                ? "MacUp could not read \(skipped) of the entries \(report.displayName) listed, and they are left out."
                : "\(report.displayName) signalled that its results are incomplete without saying which part.",
            recommendation: "Treat \(report.displayName) as unanswered rather than up to date until this is resolved."
        )
    }

    private static func describe(_ operation: ProviderOperationError.Operation) -> String {
        switch operation {
        case .detect: "find"
        case .refreshMetadata: "refresh package metadata for"
        case .inventory: "list what is installed by"
        case .outdated: "check for updates from"
        }
    }
}
