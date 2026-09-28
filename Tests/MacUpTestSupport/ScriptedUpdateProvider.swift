import Foundation
import MacUpCore

/// A provider whose verification answer a test writes in advance.
///
/// The engine locates a provider before it changes anything with it, so
/// detection answers with a stated installation. Set ``installation`` to nil
/// for a provider MacUp can no longer find. Inventory and outdated stay
/// inert: a test that reaches them has gone somewhere the engine should not.
public struct ScriptedUpdateProvider: UpdateProvider {
    public let id: ProviderID
    public let capabilities: Set<ProviderCapability> = [
        .detect, .outdated, .planUpdates, .updateSelectedItems, .verifyUpdates,
    ]
    /// What `verify` answers, or throws.
    public var verification: @Sendable (ExecutionResult, UpdateCandidate, ProviderContext) async throws -> VerificationResult
    /// What detection finds. Nil means MacUp cannot find the provider at all.
    public var installation: ProviderInstallation?

    public init(
        id: ProviderID = .homebrew,
        installation: ProviderInstallation? = ScriptedUpdateProvider.stubInstallation,
        verification: @escaping @Sendable (ExecutionResult, UpdateCandidate, ProviderContext) async throws -> VerificationResult
    ) {
        self.id = id
        self.installation = installation
        self.verification = verification
    }

    /// A plausible installation with a path no test ever launches.
    public static let stubInstallation = ProviderInstallation(
        executable: ResolvedExecutable(
            path: "/opt/homebrew/bin/brew",
            canonicalPath: "/opt/homebrew/bin/brew",
            source: .searchPath
        ),
        version: "4.0.0"
    )

    /// A provider MacUp can no longer find, so no plan of its may run.
    public static func undetectable(_ id: ProviderID = .homebrew) -> ScriptedUpdateProvider {
        ScriptedUpdateProvider(id: id, installation: nil) { _, candidate, _ in
            VerificationResult(
                item: candidate.id,
                outcome: .notPerformed,
                expectedVersion: nil,
                observedVersion: nil,
                message: "Never reached: MacUp cannot find this provider."
            )
        }
    }

    /// Answers that the planned version is now installed.
    public static func confirming(_ id: ProviderID = .homebrew) -> ScriptedUpdateProvider {
        ScriptedUpdateProvider(id: id) { _, candidate, _ in
            VerificationResult(
                item: candidate.id,
                outcome: .verified,
                expectedVersion: candidate.availableVersion.raw,
                observedVersion: candidate.availableVersion.raw,
                message: "\(candidate.displayName) is now \(candidate.availableVersion.raw)."
            )
        }
    }

    /// Answers that a different version is installed than the one planned.
    public static func reporting(observed: String, for id: ProviderID = .homebrew) -> ScriptedUpdateProvider {
        ScriptedUpdateProvider(id: id) { _, candidate, _ in
            VerificationResult(
                item: candidate.id,
                outcome: .targetNotReached,
                expectedVersion: candidate.availableVersion.raw,
                observedVersion: observed,
                message: "\(candidate.displayName) is \(observed), not \(candidate.availableVersion.raw)."
            )
        }
    }

    /// Fails to confirm anything.
    public static func failing(_ error: MacUpError, for id: ProviderID = .homebrew) -> ScriptedUpdateProvider {
        ScriptedUpdateProvider(id: id) { _, _, _ in throw error }
    }

    public func detect(context: ProviderContext) async -> ProviderStatus {
        guard let installation else { return ProviderStatus(provider: id, availability: .unavailable) }
        return ProviderStatus(provider: id, availability: .available, installation: installation)
    }

    public func inventory(context: ProviderContext) async throws -> ProviderListing<ManagedItem> {
        ProviderListing()
    }

    public func outdated(context: ProviderContext) async throws -> ProviderListing<UpdateCandidate> {
        ProviderListing()
    }

    public func verify(
        _ result: ExecutionResult,
        for candidate: UpdateCandidate,
        context: ProviderContext
    ) async throws -> VerificationResult {
        try await verification(result, candidate, context)
    }
}
