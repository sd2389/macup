import Foundation

/// Explains why a provider is not being used: it is not installed, it is
/// turned off, or MacUp found it and will not run it (CLAUDE.md §13).
///
/// A missing provider is information, not a fault. Most Macs do not have all
/// four, so "npm is not installed" is reported at `info` and never counts
/// against the machine.
public struct ProviderAvailabilityCheck: DiagnosticCheck {
    public let id = "provider.availability"
    public let title = "Whether each provider was found and can be used"

    public init() {}

    public func run(_ input: DiagnosticInput) async -> [DiagnosticFinding] {
        input.report.providers.compactMap { finding(for: $0, input: input) }
    }

    private func finding(for report: ProviderReport, input: DiagnosticInput) -> DiagnosticFinding? {
        switch report.availability {
        case .available:
            return nil
        case .disabled:
            return DiagnosticFinding(
                id: "provider.disabled",
                severity: .info,
                provider: report.provider,
                title: "\(report.displayName) is turned off in MacUp's configuration",
                detail: "MacUp ran nothing for \(report.displayName) and lists none of its updates.",
                recommendation: "Run `macup provider enable \(report.provider.rawValue)` to include it again."
            )
        case .unavailable:
            // The check engine clears the detection error for an absent
            // provider, so there is usually nothing but the plain fact.
            return DiagnosticFinding(
                id: "provider.notFound",
                severity: .info,
                provider: report.provider,
                title: "\(report.displayName) is not installed",
                detail: detail(of: report.errors.first?.error, input: input)
                    ?? "MacUp did not find \(report.displayName) on your PATH or where it is usually installed.",
                recommendation: "Nothing is wrong if you do not use \(report.displayName)."
            )
        case .failed:
            return failure(for: report, input: input)
        }
    }

    private func failure(for report: ProviderReport, input: DiagnosticInput) -> DiagnosticFinding {
        let error = report.errors.first?.error
        switch error?.kind {
        case .ambiguousOwnership:
            // The only copy is in a standard location that somebody other than
            // the user or root could modify, so resolution refused to run it.
            return DiagnosticFinding(
                id: "provider.locationNotTrusted",
                severity: .warning,
                provider: report.provider,
                title: "MacUp will not run the only copy of \(report.displayName) it found",
                detail: detail(of: error, input: input),
                recommendation: error?.recoverySuggestion
                    ?? "MacUp only runs a tool from a standard location when root or you control it and every directory above it."
            )
        case .configurationInvalid:
            return DiagnosticFinding(
                id: "provider.configuredPathUnusable",
                severity: .error,
                provider: report.provider,
                title: "The \(report.displayName) path in MacUp's configuration cannot be used",
                detail: detail(of: error, input: input),
                recommendation: error?.recoverySuggestion
                    ?? "Fix or remove providers.\(report.provider.rawValue).executablePath, then run `macup doctor` again.",
                fix: DiagnosticFix(
                    action: .clearProviderPath(report.provider),
                    summary: "Forget the configured path and let MacUp find \(report.displayName) itself",
                    detail: "Removes providers.\(report.provider.rawValue).executablePath from MacUp's "
                        + "configuration. \(report.displayName) itself is not touched, and MacUp resolves it "
                        + "the ordinary way next time."
                )
            )
        default:
            return DiagnosticFinding(
                id: "provider.unusable",
                severity: .error,
                provider: report.provider,
                title: "\(report.displayName) was found but could not be used",
                detail: detail(of: error, input: input),
                recommendation: error?.recoverySuggestion
                    ?? "MacUp reports no updates for \(report.displayName) until it can run it."
            )
        }
    }

    /// The error as one display-safe paragraph. The command and exit status
    /// are left out: they belong to the provider report, and a finding is
    /// meant to be read rather than parsed.
    private func detail(of error: MacUpError?, input: DiagnosticInput) -> String? {
        guard let error else { return nil }
        let parts = [error.message, error.detail].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return input.display(parts.joined(separator: " "))
    }
}
