import Foundation

/// Explains which installation of a runtime this Mac actually uses when
/// several provide the same command (CLAUDE.md §13).
///
/// mise can report a version as active while an earlier `PATH` entry shadows
/// it, and then two different answers are both true: mise's configuration says
/// one version, and typing the command runs another. Doctor names both and
/// says which one wins, because the difference decides where global packages
/// live and which interpreter a project gets.
public struct RuntimeOwnershipCheck: DiagnosticCheck {
    public let id = "runtime.ownership"
    public let title = "Which installation of each runtime this Mac uses"

    public init() {}

    /// One runtime command, everywhere it appears on the search path.
    private struct Candidates {
        var tool: String
        var executableName: String
        var installations: [(executable: ResolvedExecutable, owner: RuntimeOwner)]

        var first: (executable: ResolvedExecutable, owner: RuntimeOwner)? { installations.first }
        var miseManaged: ResolvedExecutable? { installations.first { $0.owner.isMiseManaged }?.executable }
    }

    public func run(_ input: DiagnosticInput) async -> [DiagnosticFinding] {
        var findings: [DiagnosticFinding] = []
        for tool in runtimes(in: input) {
            guard let candidates = resolve(tool, input: input), !candidates.installations.isEmpty else { continue }
            if let finding = shadowedByPath(candidates, input: input) {
                findings.append(finding)
            }
            if candidates.installations.count > 1 {
                findings.append(multipleInstallations(candidates, input: input))
            }
        }
        return findings
    }

    /// Runtime names MacUp has a reason to talk about: those a provider on
    /// this Mac manages, and whose command names MacUp knows for certain.
    private func runtimes(in input: DiagnosticInput) -> [String] {
        var names: Set<String> = []
        for report in input.availableReports {
            for item in report.items ?? [] where RuntimeCatalog.isRuntime(item.displayName) {
                let base = RuntimeCatalog.baseName(item.displayName)
                if !RuntimeExecutables.forTool(base).isEmpty { names.insert(base) }
            }
        }
        return names.sorted()
    }

    /// Every installation of a runtime's command on the search path, in the
    /// order a shell would search. Standard locations are deliberately left
    /// out: the question is what the user's `PATH` reaches.
    private func resolve(_ tool: String, input: DiagnosticInput) -> Candidates? {
        let homebrewPrefix = input.report(for: .homebrew)?.facts.first { $0.key == "prefix" }?.value
        for executableName in RuntimeExecutables.forTool(tool) {
            let installations = input.resolver.installations(ExecutableSearch(
                name: executableName,
                searchPath: input.searchPath
            ))
            guard !installations.isEmpty else { continue }
            return Candidates(
                tool: tool,
                executableName: executableName,
                installations: installations.map { executable in
                    (executable, RuntimeOwner.identify(
                        tool: tool,
                        path: executable.path,
                        canonicalPath: executable.canonicalPath,
                        homeDirectory: input.environment.homeDirectory,
                        miseDataDirectory: input.miseDataDirectory,
                        homebrewPrefix: homebrewPrefix
                    ))
                }
            )
        }
        return nil
    }

    /// mise reports a version active, but the command resolves elsewhere.
    private func shadowedByPath(_ candidates: Candidates, input: DiagnosticInput) -> DiagnosticFinding? {
        guard let active = miseActiveItem(candidates.tool, input: input),
              let version = active.activeVersion?.raw,
              let first = candidates.first,
              !first.owner.isMiseManaged
        else { return nil }

        var detail = "mise reports \(input.display(active.displayName)) \(input.display(version)) active"
        if let configPath = active.details["configPath"] {
            detail += " (requested in \(input.display(configPath)))"
        }
        detail += ". The first \(candidates.executableName) on your PATH is \(input.display(first.executable.path))"
        if first.executable.canonicalPath != first.executable.path {
            detail += ", which resolves to \(input.display(first.executable.canonicalPath))"
        }
        detail += " — \(first.owner.attribution)."
        if let mise = candidates.miseManaged {
            detail += " A mise-managed copy is further along your PATH at \(input.display(mise.path))."
        } else {
            detail += " No mise-managed copy is on your PATH at all."
        }

        return DiagnosticFinding(
            id: "runtime.activeVersionShadowedOnPath",
            severity: .warning,
            provider: .mise,
            title: "mise's active \(candidates.tool) is not the \(candidates.executableName) your PATH finds first",
            detail: detail,
            recommendation: recommendation(for: candidates)
        )
    }

    private func recommendation(for candidates: Candidates) -> String {
        let shared = "`mise activate` puts mise's shims ahead of other directories; "
            + "check what comes before them in your PATH."
        guard RuntimeCatalog.baseName(candidates.tool) == "node" else {
            return "Updating the mise version will not change what \(candidates.executableName) runs. " + shared
        }
        return "Global npm packages belong to the Node that runs npm, not to the version mise reports. "
            + "MacUp shows npm's own Node and global package directory under the npm provider. " + shared
    }

    private func multipleInstallations(_ candidates: Candidates, input: DiagnosticInput) -> DiagnosticFinding {
        let described = candidates.installations.map { candidate -> String in
            let path = input.display(candidate.executable.path)
            guard candidate.executable.canonicalPath != candidate.executable.path else {
                return "\(path) (\(candidate.owner.displayName))"
            }
            return "\(path) → \(input.display(candidate.executable.canonicalPath)) (\(candidate.owner.displayName))"
        }
        return DiagnosticFinding(
            id: "runtime.multipleInstallationsOnPath",
            severity: .info,
            provider: nil,
            title: "Several \(candidates.tool) installations are on your PATH",
            detail: "In PATH order: \(DiagnosticText.list(described)). "
                + "The first is what `\(candidates.executableName)` runs.",
            recommendation: "This is normal when a version manager and a package manager both install "
                + "\(candidates.tool). MacUp shows the exact executable it chose for every provider."
        )
    }

    private func miseActiveItem(_ tool: String, input: DiagnosticInput) -> ManagedItem? {
        guard let mise = input.report(for: .mise), mise.availability == .available else { return nil }
        return (mise.items ?? []).first {
            RuntimeCatalog.baseName($0.displayName) == tool && $0.activeVersion != nil
        }
    }
}
