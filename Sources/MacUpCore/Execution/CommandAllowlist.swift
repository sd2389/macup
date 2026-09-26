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
}
