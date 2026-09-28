import Foundation

/// Surfaces what ``ConfigurationValidator`` found in the configuration file
/// (CLAUDE.md §13, §14).
///
/// Every validator error is an error here too, because MacUp keeps automatic
/// modification switched off while the file has one: a misread policy could
/// let an update run that the user meant to block.
public struct ConfigurationCheck: DiagnosticCheck {
    public let id = "configuration.file"
    public let title = "Whether MacUp's configuration file can be trusted"

    public init() {}

    public func run(_ input: DiagnosticInput) async -> [DiagnosticFinding] {
        let loaded = input.configuration
        var findings = loaded.issues.map { issue(issue: $0, loaded: loaded, input: input) }
        if let from = loaded.migratedFromSchemaVersion {
            findings.append(DiagnosticFinding(
                id: "configuration.readFromOlderSchema",
                severity: .info,
                provider: nil,
                title: "MacUp read an older configuration format",
                detail: "\(input.display(loaded.path)) is schema version \(from); MacUp upgraded it in memory "
                    + "to version \(MacUpConfiguration.currentSchemaVersion) and did not change the file.",
                recommendation: "The next save writes the current format, after backing up the existing file."
            ))
        }
        return findings
    }

    private func issue(
        issue: ConfigurationIssue,
        loaded: LoadedConfiguration,
        input: DiagnosticInput
    ) -> DiagnosticFinding {
        let location = issue.path.isEmpty ? input.display(loaded.path) : input.display(issue.path)
        let message = input.display(issue.message)
        switch issue.severity {
        case .error:
            return DiagnosticFinding(
                id: "configuration.invalid",
                severity: .error,
                provider: nil,
                title: "MacUp could not accept \(location) in its configuration",
                detail: message,
                recommendation: "MacUp is using its built-in defaults for reading and keeps automatic updates "
                    + "switched off until the file is valid. Run `macup config path` to find it."
            )
        case .warning:
            return DiagnosticFinding(
                id: "configuration.questionable",
                severity: .warning,
                provider: nil,
                title: "A setting at \(location) has no effect",
                detail: message,
                recommendation: "The rest of the configuration is in use as written."
            )
        }
    }
}

/// Reports per-item policies that name something no provider has installed
/// (CLAUDE.md §13, "stale configuration").
///
/// A rule like `brew:postgresql: ignore` left over from software that has been
/// removed is harmless but misleading: it looks as though MacUp is holding
/// something back when there is nothing there. Only providers whose inventory
/// actually succeeded are considered, so a provider MacUp could not list never
/// makes a rule look stale.
public struct StaleItemPolicyCheck: DiagnosticCheck {
    public let id = "configuration.itemPolicies"
    public let title = "Whether every item policy still names installed software"

    public init() {}

    public func run(_ input: DiagnosticInput) async -> [DiagnosticFinding] {
        let listed = input.availableReports.filter { $0.items != nil }
        guard !listed.isEmpty else { return [] }
        let known = Set(listed.flatMap { ($0.items ?? []).map(\.id) })
        let inventoried = Set(listed.map(\.provider))

        var stale: [PackageID] = []
        for name in input.configuration.configuration.items.keys.sorted() {
            guard let id = try? PackageID(parsing: name),
                  inventoried.contains(id.provider),
                  !known.contains(id)
            else { continue }
            stale.append(id)
        }
        guard !stale.isEmpty else { return [] }

        return [DiagnosticFinding(
            id: "configuration.staleItemPolicy",
            severity: .info,
            provider: nil,
            title: stale.count == 1
                ? "A policy names software that is not installed"
                : "\(stale.count) policies name software that is not installed",
            detail: "No provider reports \(DiagnosticText.list(stale.map { input.display($0.rawValue) })) as installed.",
            recommendation: "The rules do nothing while the software is absent, and apply again if it comes back. "
                + "Run `macup policy clear <package-id>` to drop one."
        )]
    }
}
