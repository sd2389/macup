import Foundation

/// Looks at how many Homebrew installations this Mac has, and where the one
/// MacUp uses lives (CLAUDE.md §9, §13).
///
/// Two installations are the classic Apple Silicon situation: `/usr/local` is
/// an Intel Homebrew left over from Rosetta, `/opt/homebrew` is the native
/// one, and which one a command reaches depends entirely on `PATH`.
public struct HomebrewInstallationCheck: DiagnosticCheck {
    public let id = "homebrew.installations"
    public let title = "How many Homebrew installations this Mac has"

    /// The same locations ``HomebrewProvider`` searches, so Doctor describes
    /// the machine the way the provider sees it.
    public var standardLocations: [String]

    public init(standardLocations: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) {
        self.standardLocations = standardLocations
    }

    public func run(_ input: DiagnosticInput) async -> [DiagnosticFinding] {
        guard let report = input.report(for: .homebrew), report.availability != .disabled else { return [] }
        var findings: [DiagnosticFinding] = []

        let installations = input.resolver.installations(ExecutableSearch(
            name: "brew",
            searchPath: input.searchPath,
            standardLocations: standardLocations
        ))
        let chosen = report.executable

        // The provider already says this when Homebrew is available; the check
        // covers the case where detection stopped before it got that far.
        if installations.count > 1, !input.providerReported("homebrew.multipleInstallations") {
            let others = installations
                .filter { $0.canonicalPath != chosen?.canonicalPath }
                .map { input.display($0.path) }
            findings.append(DiagnosticFinding(
                id: "homebrew.multipleInstallations",
                severity: .warning,
                provider: .homebrew,
                title: "More than one Homebrew installation was found",
                detail: chosen.map { "MacUp uses \(input.display($0.path)). Also found: \(DiagnosticText.list(others))." }
                    ?? "Found: \(DiagnosticText.list(installations.map { input.display($0.path) }))."
                    + " MacUp is not using any of them.",
                recommendation: "On Apple Silicon, /usr/local is usually a leftover Intel installation. "
                    + "Whichever comes first in PATH is the one your shell uses."
            ))
        }

        if let chosen, let finding = prefixFinding(chosen, report: report, input: input) {
            findings.append(finding)
        }
        return findings
    }

    /// Homebrew in a custom prefix works, but only for a process whose `PATH`
    /// includes it. An app launched from Finder has to read the login shell's
    /// environment to find it at all, which is worth saying out loud.
    private func prefixFinding(
        _ executable: ResolvedExecutable,
        report: ProviderReport,
        input: DiagnosticInput
    ) -> DiagnosticFinding? {
        guard !standardLocations.contains(executable.path),
              !standardLocations.contains(executable.canonicalPath)
        else { return nil }
        let prefix = report.facts.first { $0.key == "prefix" }?.value
        return DiagnosticFinding(
            id: "homebrew.nonStandardPrefix",
            severity: .info,
            provider: .homebrew,
            title: "Homebrew is installed outside its usual location",
            detail: "MacUp uses \(input.display(executable.path))"
                + (prefix.map { ", with the prefix \(input.display($0))" } ?? "")
                + ". The usual locations are \(DiagnosticText.list(standardLocations)).",
            recommendation: "MacUp finds this Homebrew through your PATH. "
                + "Any tool that runs without your shell's environment will not find it, "
                + "so keep its directory on PATH in your shell profile."
        )
    }
}
