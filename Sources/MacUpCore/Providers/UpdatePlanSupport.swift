import Foundation

/// The pieces every provider's planning and verification code shares
/// (CLAUDE.md §11, §25).
///
/// Providers build their own commands, but they all refuse the same way and
/// they all confirm the same way. Refusing is the interesting half: an item
/// MacUp cannot name exactly, or a situation it cannot judge, produces an
/// error explaining why instead of a plan.
enum PlanSupport {
    /// The single argument that names `item`, or an error when MacUp will not
    /// pass that name to a provider.
    ///
    /// Names come from provider output, which is untrusted. They travel as
    /// one verbatim element of an argument array and are never interpolated
    /// into anything, so the shell metacharacters in a name like
    /// `$(touch /tmp/x)` are inert. What is still refused is a name a person
    /// could not read correctly in the plan they are approving, or one a
    /// provider could mistake for an option.
    static func argument(naming item: PackageID) throws -> String {
        guard ModifyingCommandRule.isAcceptablePositional(item.name) else {
            throw MacUpError(
                .unsupported,
                "MacUp will not ask \(item.provider.displayName) to change an item whose name it cannot show you exactly.",
                detail: "Name: \(TerminalText.sanitize(item.name.debugDescription))",
                recoverySuggestion: "Change this item with \(item.provider.displayName) directly if you trust the name."
            )
        }
        return item.name
    }

    /// Refuses to plan an item, with the sentence the user will read.
    static func cannotPlan(
        _ reason: String,
        detail: String? = nil,
        recoverySuggestion: String? = nil
    ) -> MacUpError {
        MacUpError(.unsupported, reason, detail: detail, recoverySuggestion: recoverySuggestion)
    }

    /// The provider installation recorded at detection, or an error saying the
    /// provider is not usable. Planning never re-detects, because building a
    /// plan must not run anything.
    static func installation(_ context: ProviderContext, _ provider: ProviderID) throws -> ProviderInstallation {
        guard let installation = context.installation else {
            throw MacUpError(
                .providerUnavailable,
                "MacUp did not record a usable \(provider.displayName) installation, so it cannot say which executable an update would run.",
                recoverySuggestion: "Run `macup check` and look at the \(provider.displayName) row."
            )
        }
        return installation
    }

    /// Whether the version a provider now reports is the one the plan promised.
    ///
    /// `observed` is what the provider reports after the update; `nil` means
    /// the item is gone. A version that differs only in spelling (`v1.2.3`
    /// against `1.2.3`) counts as reached; anything else is reported as it is
    /// rather than rounded up to success.
    static func compare(
        _ item: PackageID,
        expected: String,
        observed: String?
    ) -> VerificationResult {
        guard let observed else {
            return VerificationResult(
                item: item,
                outcome: .failed,
                expectedVersion: expected,
                observedVersion: nil,
                // An item that is gone is a state in its own right, and the
                // one history most needs to carry.
                observedState: "\(item.provider.displayName) no longer lists \(item.name).",
                message: "\(item.provider.displayName) no longer lists \(item.name), so MacUp cannot confirm what happened."
            )
        }
        if observed == expected || VersionComparator.compare(observed, expected) == .orderedSame {
            return VerificationResult(
                item: item,
                outcome: .verified,
                expectedVersion: expected,
                observedVersion: observed,
                message: "\(item.name) is now \(observed)."
            )
        }
        return VerificationResult(
            item: item,
            outcome: .targetNotReached,
            expectedVersion: expected,
            observedVersion: observed,
            message: "\(item.name) is \(observed); the plan proposed \(expected)."
        )
    }

    /// The result for a provider that could not read its own state back.
    static func unverifiable(_ item: PackageID, expected: String, because reason: String) -> VerificationResult {
        VerificationResult(
            item: item,
            outcome: .failed,
            expectedVersion: expected,
            observedVersion: nil,
            message: reason
        )
    }
}
