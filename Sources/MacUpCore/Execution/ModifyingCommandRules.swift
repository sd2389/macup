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
    /// The four shapes MacUp's providers plan, and nothing else.
    ///
    /// Each was confirmed against the installed tool's own help
    /// (docs/PROVIDER_NOTES.md records which). Every one names a single item,
    /// because an upgrade that names nothing upgrades everything and would
    /// walk past the items a user excluded.
    ///
    /// These rules bound the arguments. The other half of what a plan
    /// promises is the environment, which some guarantees live in and only
    /// in — `HOMEBREW_NO_INSTALL_CLEANUP`, for instance, has no flag — so
    /// whatever runs a step takes the environment from the owning provider's
    /// `executionEnvironment(context:)` rather than assembling one.
    public static let all: [ModifyingCommandRule] = [
        // Homebrew. `--formula` and `--cask` are explicit because one word
        // can be both, and MacUp does not let Homebrew pick which the user
        // reviewed. `--yes` answers Homebrew's own confirmation prompt, which
        // is on by default and which MacUp's subprocesses have no terminal to
        // answer; the user already confirmed the plan in MacUp.
        ModifyingCommandRule("brew", ["upgrade", "--formula", "--yes"], maximumPositionals: 1),
        ModifyingCommandRule("brew", ["upgrade", "--cask", "--yes"], maximumPositionals: 1),

        // npm, global scope only, with the version named as part of the
        // package spec so the plan and the install agree.
        ModifyingCommandRule("npm", ["install", "-g"], maximumPositionals: 1),

        // mise. `--bump` is deliberately absent: without it mise keeps the
        // version the user requested. `--cd` pins the directory mise reads
        // configuration from, so the command means the same thing wherever
        // MacUp was started; its value is the second positional.
        ModifyingCommandRule("mise", ["upgrade", "--cd"], maximumPositionals: 2),
    ]
}
