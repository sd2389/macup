import Foundation

/// Uninstalling a global npm package (docs/PROVIDER_NOTES.md).
///
/// `npm uninstall -g <package>`, confirmed against `npm help uninstall`
/// (npm 10.9.8): in global mode it removes the package from npm's global
/// folder and unlinks its commands, and touches no project's `package.json`.
/// The name is one element of the argument array, scoped names included.
extension NpmProvider {
    static func uninstallArguments(_ name: String) -> [String] { ["uninstall", "-g", name] }

    public func uninstallEnvironment(context: ProviderContext) -> [String: String] {
        executionEnvironment(context: context)
    }

    func uninstallStep(for item: ManagedItem, installation: ProviderInstallation) throws -> ExecutionStep {
        let name = try PlanSupport.argument(naming: item.id)
        return ExecutionStep(
            summary: "Uninstall the global package \(name)",
            invocation: CommandInvocation(executable: installation.executable.path, arguments: Self.uninstallArguments(name)),
            effect: .modifying,
            expectsNetwork: false,
            mayRequirePrivilege: false,
            timeoutSeconds: 600
        )
    }

    /// Whether npm still lists the package among its global packages.
    func confirmUninstalled(_ item: PackageID, context: ProviderContext) async -> UninstallCheck {
        let summary = "npm no longer lists \(item.name)"
        do {
            let installation = try PlanSupport.installation(context, id)
            let listing = try await run(Self.globalListArguments, installation, context: context, timeout: .seconds(120))
            let items = try NpmParsers.parseInventory(listing, context: NpmParsers.Context(command: listing.invocation.displayString))
            let listed = items.elements.contains { $0.id == item }
            return UninstallCheck(summary: summary, passed: !listed, detail: listed ? "npm still lists \(item.name)." : nil)
        } catch {
            return UninstallCheck(
                summary: summary,
                passed: nil,
                detail: MacUpError.wrapping(error, context: "Listing npm's global packages again").message
            )
        }
    }
}
