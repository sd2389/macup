/// Every command `macup check` may run, in one reviewable place.
///
/// ``ReadOnlyCommandGuard`` enforces this list during read-only operations.
/// Adding an entry is a trust decision: it must be a documented,
/// non-modifying provider command (CLAUDE.md §2, §26).
public enum CommandAllowlist {
    public static let readOnlyCheck: [CommandRule] = [
        // Homebrew. Every invocation also sets HOMEBREW_NO_AUTO_UPDATE=1,
        // because `brew outdated` otherwise runs `brew update` first.
        CommandRule("brew", ["--version"]),
        CommandRule("brew", ["--prefix"]),
        CommandRule("brew", ["outdated"], options: ["--json=v2"]),
        CommandRule("brew", ["info"], options: ["--json=v2", "--installed"]),
        // Which formulae run as background services, so an update can say
        // it would change one that is running. It lists; it never starts,
        // stops, or registers anything. MacUp runs it only where the command
        // is built in or already tapped, because on an older Homebrew
        // without it, `brew services` first adds the homebrew/services tap.
        CommandRule("brew", ["services", "list", "--json"]),
        // Only with `macup check --refresh`: refreshes Homebrew itself and its
        // package metadata; never upgrades installed formulae or casks.
        CommandRule("brew", ["update"], effect: .metadataRefresh),

        // npm (global scope only) and the node that runs it.
        CommandRule("npm", ["--version"]),
        CommandRule("npm", ["prefix"], options: ["-g"]),
        CommandRule("npm", ["root"], options: ["-g"]),
        CommandRule("npm", ["ls"], options: ["-g", "--json", "--depth=0"]),
        CommandRule("npm", ["outdated"], options: ["-g", "--json"]),
        CommandRule("node", ["--version"]),

        // mise. `--bump` is deliberately absent.
        CommandRule("mise", ["--version"]),
        CommandRule("mise", ["ls"], options: ["--json"]),
        CommandRule("mise", ["outdated"], options: ["--json"]),

        // macOS: listing only. `--no-scan` reads the last scan. Without it the
        // list comes from a fresh scan, which only `macup check --refresh` may run.
        CommandRule("softwareupdate", ["--list", "--no-scan"]),
        CommandRule("softwareupdate", ["--list"], effect: .metadataRefresh),
    ]

    /// Read-only commands that name one item, run only when someone asks
    /// about that item: `macup dependents`, or Show What Depends on It in the
    /// app. ``DependentsLookup`` adds these to ``readOnlyCheck``, which it
    /// still needs to find Homebrew; ``CheckEngine`` never does, so a check
    /// cannot run any of them.
    ///
    /// `brew uses --installed` reads the install records of every formula,
    /// which is why it waits to be asked. The one positional is the formula,
    /// and it is checked like a modifying command's: nothing that starts with
    /// `-`, nothing a terminal would not show. `--formula` and `--cask` are
    /// separate rules, run separately, so MacUp never has to guess which kind
    /// of thing a name in the answer is.
    public static let dependentsLookup: [CommandRule] = [
        CommandRule("brew", ["uses", "--installed", "--formula"], positionalCount: 1),
        CommandRule("brew", ["uses", "--installed", "--cask"], positionalCount: 1),
    ]
}
