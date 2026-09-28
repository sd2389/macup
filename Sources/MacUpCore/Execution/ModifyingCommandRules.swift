import Foundation

/// One shape of modifying command MacUp may ever run.
///
/// A rule differs from ``CommandRule`` in one way that matters: a modifying
/// command names the thing it changes, so positional arguments are allowed.
/// They are also the dangerous part, so they are checked rather than trusted:
/// a positional may not look like an option, and may not contain anything a
/// terminal or a provider could misread.
public struct ModifyingCommandRule: Sendable, Hashable {
    /// File name of the executable, for example `brew`.
    public var executableName: String
    /// Arguments the command must start with, for example `["upgrade"]`.
    public var leadingArguments: [String]
    /// Options that may appear after ``leadingArguments``.
    public var allowedOptions: Set<String>
    /// How many positional arguments (package names) may follow. Every
    /// MacUp plan names one item, so this is 1 for per-item upgrades.
    public var maximumPositionals: Int
    public var effect: CommandEffect

    public init(
        _ executableName: String,
        _ leadingArguments: [String],
        options: Set<String> = [],
        maximumPositionals: Int = 0,
        effect: CommandEffect = .modifying
    ) {
        self.executableName = executableName
        self.leadingArguments = leadingArguments
        self.allowedOptions = options
        self.maximumPositionals = maximumPositionals
        self.effect = effect
    }

    public func matches(_ request: CommandRequest) -> Bool {
        guard request.effect == effect, request.executable.lastPathComponent == executableName else { return false }
        let arguments = request.arguments
        guard arguments.count >= leadingArguments.count,
              Array(arguments.prefix(leadingArguments.count)) == leadingArguments
        else { return false }

        var positionals = 0
        for argument in arguments.dropFirst(leadingArguments.count) {
            if allowedOptions.contains(argument) { continue }
            guard Self.isAcceptablePositional(argument) else { return false }
            positionals += 1
        }
        return positionals <= maximumPositionals
    }

    /// Whether an argument is safe to pass as a positional.
    ///
    /// Anything starting with `-` is refused because a provider could read it
    /// as an option, and anything with control or bidirectional-override
    /// characters is refused because a person reading the plan would not see
    /// what MacUp is about to run.
    public static func isAcceptablePositional(_ argument: String) -> Bool {
        guard !argument.isEmpty, !argument.hasPrefix("-"), argument.count <= PackageID.maximumNameLength else {
            return false
        }
        if argument.unicodeScalars.contains(where: TerminalText.isUnsafe) { return false }
        return !argument.contains("\0") && argument.trimmingCharacters(in: .whitespacesAndNewlines) == argument
    }
}

/// Every modifying command MacUp may run, in one reviewable place.
///
/// This is the counterpart of ``CommandAllowlist``: that list bounds what a
/// check may do, this one bounds what an update may do. Adding an entry is a
/// trust decision (CLAUDE.md §2, §26). ``ExecutionGuard`` enforces it, on top
/// of requiring that the command was in the plan the user reviewed.
public enum ModifyingCommandRules {
    /// Populated by the provider planning work; empty means MacUp can run
    /// nothing modifying, which is the right answer until a provider's
    /// commands have been reviewed and tested.
    public static let all: [ModifyingCommandRule] = []
}
