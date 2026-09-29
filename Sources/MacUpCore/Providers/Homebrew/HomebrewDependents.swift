import Foundation

/// What depends on one installed formula, from `brew uses --installed`
/// (confirmed against Homebrew 7.0.6).
///
/// With `--installed` and nothing else, Homebrew answers from the install
/// records of what is installed: every formula whose record lists the
/// formula as a run-time dependency, directly or through another formula,
/// and every installed cask that depends on it. It prints one full name per
/// line and nothing when there are none. It is read-only, but it reads the
/// record of every installed formula, which is why MacUp asks only when
/// someone does.
///
/// Formulae and casks are asked for separately (`--formula`, `--cask`), so
/// MacUp never has to guess which kind a name in the answer is: one word can
/// be both. A name Homebrew does not know produces a warning on standard
/// error and an empty answer with exit status 0, which is why an empty
/// answer that came with a warning is not taken to mean "nothing".
extension HomebrewProvider {
    static func dependentsArguments(of name: String, casks: Bool) -> [String] {
        ["uses", "--installed", casks ? "--cask" : "--formula", name]
    }

    /// Homebrew lists what depends on formulae. A cask is not something
    /// other software declares a dependency on in a way `brew uses` reads.
    public func canListDependents(of item: PackageID) -> Bool {
        item.namespace == .brew
    }

    public func dependents(of item: PackageID, context: ProviderContext) async throws -> ProviderListing<PackageID> {
        guard canListDependents(of: item) else {
            throw MacUpError(
                .unsupported,
                "Homebrew lists what depends on a formula, and \(item.rawValue) is not one.",
                recoverySuggestion: "Ask about a formula instead, for example brew:openssl@3."
            )
        }
        // The name travels as one argument and is never interpolated; what is
        // refused is a name nobody could read correctly, or one Homebrew
        // could mistake for an option.
        guard ModifyingCommandRule.isAcceptablePositional(item.name) else {
            throw MacUpError(
                .unsupported,
                "MacUp will not ask Homebrew about an item whose name it cannot show you exactly.",
                detail: "Name: \(TerminalText.sanitize(item.name.debugDescription))"
            )
        }
        let installation = try await requireInstallation(context)
        async let formulae = run(Self.dependentsArguments(of: item.name, casks: false), installation, context: context, timeout: .seconds(300))
        async let casks = run(Self.dependentsArguments(of: item.name, casks: true), installation, context: context, timeout: .seconds(300))
        let (formulaResult, caskResult) = try await (formulae, casks)

        var listing = ProviderListing<PackageID>()
        try HomebrewDependentsParser.parse(formulaResult, namespace: .brew, asking: item, into: &listing)
        try HomebrewDependentsParser.parse(caskResult, namespace: .brewCask, asking: item, into: &listing)
        listing.elements = Array(Set(listing.elements)).sorted()
        return listing
    }
}

/// Reads one `brew uses --installed` answer.
enum HomebrewDependentsParser {
    static func parse(
        _ result: CommandResult,
        namespace: PackageNamespace,
        asking item: PackageID,
        into listing: inout ProviderListing<PackageID>
    ) throws {
        guard result.succeeded else {
            throw MacUpError.commandFailed(result, "`brew uses` failed, so MacUp cannot say what depends on \(item.name).")
        }
        // One name per line when the output is not a terminal, as it never is
        // here. Splitting on any whitespace also reads Homebrew's columns, and
        // no formula or cask name contains a space.
        let names = result.standardOutputText.split(whereSeparator: \.isWhitespace).map(String.init)
        if names.isEmpty, let warning = TextExcerpt.tail(of: result.standardErrorText, maxLines: 4) {
            throw MacUpError(
                .parseFailed,
                "Homebrew listed nothing for \(item.name) and printed a warning instead, so MacUp cannot tell whether anything depends on it.",
                detail: warning,
                command: Redactor().redact(result.invocation.displayString),
                recoverySuggestion: "Run `brew uses --installed` with its name yourself to see what Homebrew says."
            )
        }
        for name in names {
            do {
                listing.elements.append(try PackageID(namespace, name))
            } catch let error as PackageID.ValidationError {
                listing.skip(ProviderSupport.skippedName(name, reason: error, provider: .homebrew))
            }
        }
    }
}
