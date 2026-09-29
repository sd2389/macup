import Foundation

/// One command shape that may run during a read-only operation.
public struct CommandRule: Sendable, Hashable {
    /// File name of the executable, for example `brew`.
    public var executableName: String
    /// Arguments the command must start with, for example `["outdated"]`.
    public var leadingArguments: [String]
    /// Every argument after `leadingArguments` must be one of these, apart
    /// from exactly ``positionalCount`` positionals.
    public var allowedOptions: Set<String>
    /// How many positional arguments must follow — exactly that many.
    ///
    /// Zero for every rule a check uses, because a check never names a
    /// package: that is what makes a read-only command structurally unable
    /// to act on one. A lookup someone asked for about one item has to name
    /// it, and that name is checked the way a modifying command's is
    /// (``ModifyingCommandRule/isAcceptablePositional(_:)``).
    public var positionalCount: Int
    public var effect: CommandEffect

    public init(
        _ executableName: String,
        _ leadingArguments: [String],
        options: Set<String> = [],
        positionalCount: Int = 0,
        effect: CommandEffect = .readOnly
    ) {
        self.executableName = executableName
        self.leadingArguments = leadingArguments
        self.allowedOptions = options
        self.positionalCount = positionalCount
        self.effect = effect
    }

    public func matches(_ request: CommandRequest) -> Bool {
        guard request.effect == effect, request.executable.lastPathComponent == executableName else { return false }
        let arguments = request.arguments
        guard arguments.count >= leadingArguments.count,
              Array(arguments.prefix(leadingArguments.count)) == leadingArguments
        else { return false }
        var positionals = 0
        for argument in arguments.dropFirst(leadingArguments.count) where !allowedOptions.contains(argument) {
            guard ModifyingCommandRule.isAcceptablePositional(argument) else { return false }
            positionals += 1
        }
        return positionals == positionalCount
    }
}

/// Wraps a runner so read-only operations can only launch allowlisted,
/// non-modifying commands.
///
/// This is defense in depth. Providers already construct only read-only
/// commands while checking; the guard makes that a structural guarantee
/// rather than a convention, and fails closed on anything unexpected.
public struct ReadOnlyCommandGuard: CommandRunning {
    public var base: any CommandRunning
    public var rules: [CommandRule]
    /// Allows `.metadataRefresh` commands on the allowlist (`macup check --refresh`).
    public var allowsMetadataRefresh: Bool

    public init(base: any CommandRunning, rules: [CommandRule], allowsMetadataRefresh: Bool = false) {
        self.base = base
        self.rules = rules
        self.allowsMetadataRefresh = allowsMetadataRefresh
    }

    public func run(_ request: CommandRequest, output: CommandOutputHandler?) async throws -> CommandResult {
        let display = Redactor().redact(request.invocation.displayString)
        switch request.effect {
        case .modifying:
            throw MacUpError(
                .policyDenied,
                "MacUp refused to run a modifying command during a read-only operation.",
                command: display
            )
        case .metadataRefresh where !allowsMetadataRefresh:
            throw MacUpError(
                .policyDenied,
                "MacUp refused to refresh provider metadata because a refresh was not requested.",
                command: display,
                recoverySuggestion: "Use `macup check --refresh` to refresh provider metadata."
            )
        case .metadataRefresh, .readOnly:
            break
        }
        guard rules.contains(where: { $0.matches(request) }) else {
            throw MacUpError(
                .policyDenied,
                "MacUp refused to run a command that is not on the read-only allowlist.",
                command: display
            )
        }
        return try await base.run(request, output: output)
    }
}
