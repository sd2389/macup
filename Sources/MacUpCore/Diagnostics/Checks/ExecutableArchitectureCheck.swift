import Foundation

/// Reports a provider binary built for an architecture this Mac is not
/// (CLAUDE.md §13, "binary architecture mismatch if discoverable").
///
/// An Intel binary on Apple Silicon runs, through Rosetta 2, and is usually a
/// leftover from a migrated machine: slow, and a sign that the whole
/// installation below it is Intel too. An Apple Silicon binary on an Intel Mac
/// cannot run at all.
///
/// Most provider entry points are scripts — `brew` is bash, `npm` is a Node
/// script — so there is nothing to read; the check also looks at the `node`
/// that runs npm, which is a real binary. A header MacUp cannot interpret is
/// left unreported rather than guessed at, which is what "if discoverable"
/// means.
public struct ExecutableArchitectureCheck: DiagnosticCheck {
    public let id = "provider.architecture"
    public let title = "Whether every provider binary matches this Mac"

    public var reader: any ExecutableArchitectureReading

    public init(reader: any ExecutableArchitectureReading = MachOArchitectureReader()) {
        self.reader = reader
    }

    /// One executable worth reading, and how to describe it.
    private struct Subject {
        var provider: ProviderID
        var label: String
        var path: String
    }

    public func run(_ input: DiagnosticInput) async -> [DiagnosticFinding] {
        let host = input.environment.system.architecture
        // Without a known host architecture there is nothing to compare
        // against, and a comparison MacUp cannot make is not a finding.
        guard ["arm64", "x86_64"].contains(host) else { return [] }

        var findings: [DiagnosticFinding] = []
        var seen: Set<String> = []
        for subject in subjects(in: input) where seen.insert(subject.path).inserted {
            guard case .machO(let architectures) = reader.architectures(ofExecutableAt: subject.path),
                  !architectures.isEmpty,
                  !architectures.contains(host)
            else { continue }
            findings.append(finding(subject, architectures: architectures, host: host, input: input))
        }
        return findings
    }

    private func subjects(in input: DiagnosticInput) -> [Subject] {
        var subjects: [Subject] = []
        for report in input.availableReports {
            if let executable = report.executable {
                subjects.append(Subject(
                    provider: report.provider,
                    label: "The \(report.displayName) executable",
                    path: executable.canonicalPath
                ))
            }
            // npm is a script; the Node that runs it is the binary that has to
            // match the Mac, and it is the one MacUp recorded as its owner.
            if report.provider == .npm {
                let node = report.facts.first { $0.key == NpmProvider.FactKey.nodeTarget }?.value
                    ?? report.facts.first { $0.key == NpmProvider.FactKey.nodePath }?.value
                if let node {
                    subjects.append(Subject(provider: .npm, label: "The Node that runs npm", path: node))
                }
            }
        }
        return subjects
    }

    private func finding(
        _ subject: Subject,
        architectures: [String],
        host: String,
        input: DiagnosticInput
    ) -> DiagnosticFinding {
        let built = DiagnosticText.list(architectures)
        let runnable = host == "arm64" && architectures.contains("x86_64")
        return DiagnosticFinding(
            id: "provider.architectureMismatch",
            severity: runnable ? .warning : .error,
            provider: subject.provider,
            title: runnable
                ? "\(subject.label) is an Intel binary on an Apple Silicon Mac"
                : "\(subject.label) was not built for this Mac",
            detail: "\(input.display(subject.path)) is built for \(built); this Mac is \(host).",
            recommendation: runnable
                ? "It runs through Rosetta 2. This usually means the whole installation came from an Intel Mac; "
                    + "reinstalling it natively is faster and keeps the packages under it native too."
                : "MacUp cannot run this binary on this Mac. Reinstall the tool for \(host)."
        )
    }
}
