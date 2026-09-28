import ArgumentParser
import MacUpCore

/// Package IDs named on the command line.
///
/// Both `macup plan` and `macup update` accept them, and both refuse the whole
/// command when one is not a package ID: acting on the arguments MacUp
/// understood and quietly dropping the rest is how somebody ends up believing
/// an item was handled (CLAUDE.md §2.23).
enum PackageSelection {
    /// The items to act on, or `nil` for every item found.
    static func parse(_ arguments: [String]) -> Set<PackageID>? {
        guard !arguments.isEmpty else { return nil }
        return Set(arguments.compactMap { try? PackageID(parsing: $0) })
    }

    /// Rejects anything that is not a package ID, from `validate()`, so the
    /// command never starts.
    static func validate(_ arguments: [String]) throws {
        for argument in arguments {
            do {
                _ = try PackageID(parsing: argument)
            } catch let error as PackageID.ValidationError {
                throw ValidationError(error.description)
            }
        }
    }

    /// The message for IDs that are package IDs but that no provider offered
    /// an update for. MacUp says so and changes nothing, rather than acting on
    /// the subset it recognized.
    static func unmatchedMessage(_ items: [PackageID]) -> String {
        let names = items.map { TerminalText.sanitize($0.rawValue) }.joined(separator: ", ")
        return items.count == 1
            ? "No update is available for \(names), so MacUp has nothing to do for it."
            : "No updates are available for these items, so MacUp has nothing to do for them: \(names)."
    }
}
