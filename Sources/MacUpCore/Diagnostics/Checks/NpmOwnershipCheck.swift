import Foundation

/// Explains which Node installation owns the global npm packages MacUp lists
/// (CLAUDE.md §9, §13).
///
/// Global packages hang off one Node installation and one prefix. When mise
/// manages an active Node but npm runs a different one, the packages MacUp
/// lists are not the ones a developer expects from `mise ls`, and no amount of
/// changing the mise version will move them. The npm provider cannot see this
/// on its own, because it never looks at mise.
public struct NpmOwnershipCheck: DiagnosticCheck {
    public let id = "npm.ownership"
    public let title = "Which Node installation owns the global npm packages"

    public init() {}

    public func run(_ input: DiagnosticInput) async -> [DiagnosticFinding] {
        guard let npm = input.report(for: .npm), npm.availability == .available else { return [] }
        var findings: [DiagnosticFinding] = []
        if let finding = nodeNotManagedByMise(npm, input: input) { findings.append(finding) }
        if let finding = globalPrefixOutsideNode(npm, input: input) { findings.append(finding) }
        return findings
    }

    /// mise has an active Node, and it is not the one running npm.
    private func nodeNotManagedByMise(_ npm: ProviderReport, input: DiagnosticInput) -> DiagnosticFinding? {
        guard let nodePath = npm.facts.first(where: { $0.key == NpmProvider.FactKey.nodePath })?.value,
              let active = miseActiveNode(input)
        else { return nil }
        let nodeTarget = npm.facts.first { $0.key == NpmProvider.FactKey.nodeTarget }?.value ?? nodePath
        guard !RuntimeOwner.isUnderMise(
            path: nodePath,
            canonicalPath: nodeTarget,
            miseDataDirectory: input.miseDataDirectory
        ) else { return nil }

        let nodeVersion = npm.facts.first { $0.key == NpmProvider.FactKey.nodeVersion }?.value
        let manager = npm.facts.first { $0.key == NpmProvider.FactKey.nodeManager }?.value
        let globalRoot = npm.facts.first { $0.key == NpmProvider.FactKey.globalRoot }?.value

        var detail = "mise reports node \(input.display(active)) active. "
        detail += "The npm MacUp uses is \(input.display(npm.executable?.path ?? "npm")), "
        detail += "and it runs \(input.display(nodeTarget))"
        if let nodeVersion { detail += " (\(input.display(nodeVersion)))" }
        if let manager, manager != NodeManager.unknown.displayName {
            detail += ", installed by \(input.display(manager))"
        }
        detail += "."
        if let globalRoot {
            detail += " The global packages MacUp lists are the ones in \(input.display(globalRoot))."
        }

        return DiagnosticFinding(
            id: "npm.nodeNotManagedByMise",
            severity: .warning,
            provider: .npm,
            title: "The npm MacUp uses does not belong to mise's active Node",
            detail: detail,
            recommendation: "Global npm packages belong to one Node installation. "
                + "The list MacUp shows is the one this npm reports, not the one mise's node would report. "
                + "Check which node and npm come first on your PATH before installing global tools."
        )
    }

    /// The global prefix sits outside the Node installation that runs npm, so
    /// the packages survive a Node change but are only reachable while the
    /// prefix's `bin` directory is on `PATH`.
    private func globalPrefixOutsideNode(_ npm: ProviderReport, input: DiagnosticInput) -> DiagnosticFinding? {
        guard let prefix = npm.facts.first(where: { $0.key == NpmProvider.FactKey.globalPrefix })?.value,
              let nodePath = npm.facts.first(where: { $0.key == NpmProvider.FactKey.nodePath })?.value
        else { return nil }
        let nodeTarget = npm.facts.first { $0.key == NpmProvider.FactKey.nodeTarget }?.value ?? nodePath
        // A Node installation lays out bin/, lib/, and include/ under one
        // prefix, so its own prefix is the grandparent of the executable.
        let nodePrefix = ((nodeTarget as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        guard prefix != nodePrefix else { return nil }

        let globalRoot = npm.facts.first { $0.key == NpmProvider.FactKey.globalRoot }?.value
        return DiagnosticFinding(
            id: "npm.globalPrefixOutsideNode",
            severity: .info,
            provider: .npm,
            title: "npm installs global packages outside its Node installation",
            detail: "npm's global prefix is \(input.display(prefix))"
                + (globalRoot.map { ", so packages go to \(input.display($0))" } ?? "")
                + ", while the Node that runs npm lives under \(input.display(nodePrefix)).",
            recommendation: "This is how a custom npm prefix behaves: the packages stay put when you change "
                + "Node versions, but their commands only work while \(input.display(prefix))/bin is on your PATH."
        )
    }

    private func miseActiveNode(_ input: DiagnosticInput) -> String? {
        guard let mise = input.report(for: .mise), mise.availability == .available else { return nil }
        return (mise.items ?? [])
            .first { ["node", "nodejs"].contains(RuntimeCatalog.baseName($0.displayName)) }?
            .activeVersion?.raw
    }
}
