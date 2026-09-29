import Foundation

/// Uninstalling one installed version of a mise tool
/// (docs/PROVIDER_NOTES.md).
///
/// `mise uninstall <tool>@<version>`, confirmed against `mise uninstall
/// --help` (mise 2026.7.3), which says: "This only removes the installed
/// version, it does not modify mise.toml." The version is the exact one mise
/// reports as installed, so the command names one installation and nothing
/// fuzzy; `--all` is never passed. MacUp never edits mise's configuration
/// either, so when the version removed is the one a configuration asks for,
/// the plan says that file still names it.
extension MiseProvider {
    static func uninstallArguments(tool: String, version: String) -> [String] { ["uninstall", "\(tool)@\(version)"] }

    /// Characters an installed version may contain. mise names installs by
    /// the version it resolved, so anything else is refused rather than
    /// repeated back to it.
    private static let versionCharacters = Set("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-+_")

    public func uninstallEnvironment(context: ProviderContext) -> [String: String] {
        executionEnvironment(context: context)
    }

    func uninstallStep(tool item: ManagedItem, version: String, installation: ProviderInstallation) throws -> ExecutionStep {
        let tool = try PlanSupport.argument(naming: item.id)
        guard !version.isEmpty, version.count <= 64, version.allSatisfy({ Self.versionCharacters.contains($0) }),
              item.installedVersions.contains(where: { $0.raw == version })
        else {
            throw PlanSupport.cannotPlan(
                "MacUp will not ask mise to remove \(tool) \(TerminalText.sanitize(version)): it is not a version mise lists as installed.",
                recoverySuggestion: "`mise ls \(ShellWord.isPlain(tool) ? tool : "<tool>")` lists what is installed."
            )
        }
        return ExecutionStep(
            summary: "Uninstall \(tool) \(version)",
            invocation: CommandInvocation(
                executable: installation.executable.path,
                arguments: Self.uninstallArguments(tool: tool, version: version)
            ),
            effect: .modifying,
            expectsNetwork: false,
            mayRequirePrivilege: false,
            timeoutSeconds: 600
        )
    }

    /// Whether mise still lists that version as installed.
    func confirmUninstalled(tool: PackageID, version: String, context: ProviderContext) async -> UninstallCheck {
        let summary = "mise no longer lists \(tool.name) \(version)"
        do {
            let installation = try PlanSupport.installation(context, id)
            let listing = try await run(Self.toolListArguments, installation, context: context, timeout: .seconds(120))
            guard listing.succeeded else {
                return UninstallCheck(summary: summary, passed: nil, detail: "`mise ls` failed afterwards, so MacUp could not check.")
            }
            let items = try MiseParsers.parseInventory(
                listing.standardOutput,
                context: parserContext(installation, context: context, command: listing.invocation.displayString)
            )
            let listed = items.elements.contains { $0.id == tool && $0.installedVersions.contains { $0.raw == version } }
            return UninstallCheck(
                summary: summary,
                passed: !listed,
                detail: listed ? "mise still lists \(tool.name) \(version) as installed." : nil
            )
        } catch {
            return UninstallCheck(
                summary: summary,
                passed: nil,
                detail: MacUpError.wrapping(error, context: "Listing mise's tools again").message
            )
        }
    }
}
