import Foundation

/// Makes text fit to leave the Mac in an exported diagnostics file
/// (CLAUDE.md §16, §18).
///
/// Every string ``DiagnosticsDocument`` writes passes through here: secrets
/// are redacted, the home directory becomes `~`, the account name on its own
/// becomes `<user>`, package names become placeholders unless the user asked
/// for them, and control and bidirectional-override characters become visible
/// escapes. Like ``Redactor`` it is deliberately over-eager: a word lost to a
/// placeholder is a small price, a name or a token that got through is not.
///
/// A reference type because placeholders are numbered as they are first used,
/// and every section of one document must share the numbering.
final class DiagnosticsScrubber {
    private let redactor: Redactor
    private let userName: NSRegularExpression?
    private let names: PackageNameMask?

    init(homeDirectory: String, packageNames: PackageNameMask?) {
        redactor = Redactor(homeDirectory: homeDirectory)
        userName = Self.userNameExpression(homeDirectory: homeDirectory)
        names = packageNames
    }

    /// Free text: messages, findings, commands, paths, versions.
    func text(_ value: String) -> String {
        var result = redactor.redact(value)
        if let userName {
            let range = NSRange(result.startIndex..., in: result)
            result = userName.stringByReplacingMatches(in: result, range: range, withTemplate: "<user>")
        }
        if let names { result = names.masking(result) }
        return TerminalText.sanitize(result)
    }

    func text(_ value: String?) -> String? {
        value.map(text)
    }

    /// A package ID, as the file writes it: `brew:git`, or `brew:package-1`.
    func item(_ id: PackageID) -> String {
        names?.placeholder(for: id) ?? id.rawValue
    }

    func error(_ error: MacUpError) -> MacUpError {
        var copy = error
        copy.message = text(error.message)
        copy.detail = text(error.detail)
        copy.command = text(error.command)
        copy.recoverySuggestion = text(error.recoverySuggestion)
        return copy
    }

    func finding(_ finding: DiagnosticFinding) -> DiagnosticFinding {
        var copy = finding
        copy.title = text(finding.title)
        copy.recommendation = text(finding.recommendation)
        copy.detail = text(Self.withoutUnreadableName(finding, masking: names != nil))
        return copy
    }

    /// A finding about an entry MacUp could not read names the entry first,
    /// as it was written, then says why. Such a name was never parsed into a
    /// package ID, so the mask has never heard of it and cannot catch it; it
    /// is dropped outright, and only the reason is kept.
    private static func withoutUnreadableName(_ finding: DiagnosticFinding, masking: Bool) -> String? {
        guard masking, let detail = finding.detail,
              finding.id.hasSuffix(".unusableName") || finding.id.hasSuffix(".unreadableEntry")
        else { return finding.detail }
        // The reason is MacUp's own text and never contains the name after
        // its last ": ", so everything before that is dropped.
        guard let separator = detail.range(of: ": ", options: .backwards) else {
            return "(name left out)"
        }
        return "(name left out): " + detail[separator.upperBound...]
    }

    /// The account name on its own, as a whole word. `~` already covers it
    /// inside the home path; this catches it everywhere else, such as a
    /// provider's "fix the owner with chown" advice. Names shorter than three
    /// characters are left alone, because masking every "me" or "a" in the
    /// file would make it unreadable without protecting anything.
    private static func userNameExpression(homeDirectory: String) -> NSRegularExpression? {
        let home = PathDisplay.standardized(homeDirectory)
        guard home.hasPrefix("/"), home != "/" else { return nil }
        let name = (home as NSString).lastPathComponent
        guard name.count >= 3 else { return nil }
        return try? NSRegularExpression(
            pattern: PackageNameMask.boundaryBefore + NSRegularExpression.escapedPattern(for: name) + PackageNameMask.boundaryAfter
        )
    }
}

/// Replaces package names with placeholders such as `brew:package-1`.
///
/// A name is numbered the first time the file uses it and keeps that number
/// everywhere after, so an update, a history entry, and a rule about the same
/// package can still be matched up. Numbering by first use rather than
/// alphabetically means a number gives away nothing about names the file
/// never shows. The same name under two providers (`brew:node` and
/// `mise:node`) gets the same number, because free text such as a command
/// line names a package without saying which provider it belongs to.
///
/// Names that are MacUp's own vocabulary are kept (``isMacUpVocabulary(_:)``).
final class PackageNameMask {
    /// A name starts and ends where a letter or digit does not continue it,
    /// so `git` is masked in `/opt/homebrew/bin/git` and `git-lfs-3.5` but
    /// not in `digit` or `GitHub`.
    static let boundaryBefore = #"(?<![\p{L}\p{N}])"#
    static let boundaryAfter = #"(?![\p{L}\p{N}])"#

    /// Lowercased spelling (a name, or another name for it such as a cask's
    /// "Visual Studio Code") → the name whose number it shares.
    private var spellings: [String: String] = [:]
    /// Lowercased name → its number, assigned on first use.
    private var numbers: [String: Int] = [:]
    private let expression: NSRegularExpression?

    /// `names` are every package name the file could mention, each with any
    /// other names the provider gives it. Nothing is numbered yet.
    init(names: [(name: String, alsoKnownAs: [String])]) {
        for entry in names where !Self.isMacUpVocabulary(entry.name) {
            let key = entry.name.lowercased()
            spellings[key] = key
            for other in entry.alsoKnownAs {
                let spelling = other.lowercased()
                // Another package's own name wins over a display name, and a
                // display name that is MacUp's vocabulary ("Node") would mask
                // MacUp's own sentences, so neither is taken as an alias.
                guard !spelling.isEmpty, spellings[spelling] == nil, !Self.isMacUpVocabulary(spelling) else { continue }
                spellings[spelling] = key
            }
        }
        // Longest first, so `visual-studio-code` is masked whole rather than
        // as `visual-studio-` and a separately masked `code`.
        let alternatives = spellings.keys
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .map(NSRegularExpression.escapedPattern(for:))
        expression = alternatives.isEmpty ? nil : try? NSRegularExpression(
            pattern: Self.boundaryBefore + "(?:" + alternatives.joined(separator: "|") + ")" + Self.boundaryAfter,
            options: [.caseInsensitive]
        )
    }

    /// `brew:package-1`, or the ID itself when its name is MacUp's vocabulary.
    func placeholder(for id: PackageID) -> String {
        guard !Self.isMacUpVocabulary(id.name) else { return id.rawValue }
        return id.namespace.rawValue + ":" + placeholder(forName: id.name.lowercased())
    }

    /// `text` with every known package name in it replaced.
    func masking(_ text: String) -> String {
        guard let expression else { return text }
        let source = text as NSString
        var result = ""
        var location = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: location, length: match.range.location - location))
            let spelling = source.substring(with: match.range).lowercased()
            result += placeholder(forName: spellings[spelling] ?? spelling)
            location = match.range.location + match.range.length
        }
        return result + source.substring(from: location)
    }

    private func placeholder(forName key: String) -> String {
        if let number = numbers[key] { return "package-\(number)" }
        let number = numbers.count + 1
        numbers[key] = number
        return "package-\(number)"
    }

    /// Whether a name belongs to MacUp rather than to the user: a language
    /// runtime or package manager that MacUp's own source recognizes by name
    /// (``RuntimeCatalog``), bare or as a Homebrew versioned formula such as
    /// `python@3.12`.
    ///
    /// These stay, because MacUp's findings are written in terms of them
    /// ("Node is installed twice") and masking them would garble MacUp's own
    /// sentences while hiding nothing specific to this Mac. A scope or a
    /// backend prefix (`@acme/node`, `npm:prettier`) makes a name somebody's
    /// own, so those are masked like any other.
    static func isMacUpVocabulary(_ name: String) -> Bool {
        let lowered = name.lowercased()
        guard !lowered.isEmpty, !lowered.hasPrefix("@"), !lowered.contains("/"), !lowered.contains(":") else {
            return false
        }
        return RuntimeCatalog.isRuntime(lowered) || RuntimeCatalog.isPackageManager(lowered)
    }
}
