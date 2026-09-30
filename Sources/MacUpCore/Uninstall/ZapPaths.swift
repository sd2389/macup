import Darwin
import Foundation

/// One path pattern a Homebrew cask's `zap` stanza lists.
public struct ZapDirective: Sendable, Hashable, Codable {
    public enum Action: String, Sendable, Hashable, Codable {
        /// Homebrew would move it to the Trash.
        case trash
        /// Homebrew would delete it.
        case delete
        /// Homebrew would remove the folder only if it is empty.
        case rmdir
    }

    public var action: Action
    /// As the cask wrote it: `~/Library/Caches/com.example.App`, possibly
    /// with `*`, `?`, `[…]`, or `{a,b}` in it.
    public var pattern: String

    public init(action: Action, pattern: String) {
        self.action = action
        self.pattern = pattern
    }
}

/// Turns a cask's `zap` patterns into the paths they name on this Mac.
///
/// Expanded in code, as Homebrew's own `Pathname.glob` would, and read-only:
/// `~` is the home folder, `{a,b}` offers both, and `*`, `?`, and `[…]` match
/// within one path component the way `fnmatch(3)` does, with a leading dot
/// matched only explicitly. Two things are refused rather than guessed at: a
/// relative pattern, and `**`, which would match at any depth. Expansion
/// never looks inside a link, so a pattern cannot be walked out of the folder
/// it names.
struct ZapPathExpander: Sendable {
    var homeDirectory: String
    /// A pattern that matches more than this is not trusted to mean what the
    /// cask meant.
    var maximumMatches = 200

    enum Expansion: Sendable, Hashable {
        /// Paths that exist now, sorted.
        case paths([String])
        /// MacUp will not expand this, and says why.
        case refused(String)
    }

    func expand(_ pattern: String) -> Expansion {
        guard !pattern.isEmpty, !pattern.contains("\0"), !pattern.unicodeScalars.contains(where: TerminalText.isUnsafe) else {
            return .refused("The pattern contains characters MacUp cannot show you exactly.")
        }
        guard !pattern.contains("**") else {
            return .refused("The pattern uses **, which matches at any depth, so MacUp does not expand it.")
        }
        var found = Set<String>()
        for alternative in Self.braces(pattern) {
            let absolute: String
            if alternative == "~" {
                absolute = homeDirectory
            } else if alternative.hasPrefix("~/") {
                absolute = homeDirectory + alternative.dropFirst()
            } else if alternative.hasPrefix("/") {
                absolute = alternative
            } else {
                return .refused("The pattern is not an absolute path or one in your home folder.")
            }
            let components = absolute.split(separator: "/").map(String.init)
            guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
                return .refused("The pattern steps up out of the folder it names.")
            }
            found.formUnion(match(components[...], under: "/"))
            if found.count > maximumMatches {
                return .refused("The pattern matches more than \(maximumMatches) items, so MacUp does not trust it to mean what it says.")
            }
        }
        return .paths(found.sorted())
    }

    /// Walks the components one at a time: a plain name is looked up, a
    /// pattern is matched against the names in the folder so far. Only real
    /// folders are entered; a link is matched as the last component or not
    /// at all.
    private func match(_ components: ArraySlice<String>, under base: String) -> [String] {
        guard let first = components.first else { return [base] }
        let rest = components.dropFirst()
        let prefix = base == "/" ? "/" : base + "/"
        let candidates: [String]
        if Self.isPattern(first) {
            candidates = (FileTree.names(in: base) ?? []).filter { Self.matches(first, $0) }.map { prefix + $0 }
        } else {
            candidates = [prefix + first]
        }
        var results: [String] = []
        for candidate in candidates {
            guard let status = FileTree.status(candidate) else { continue }
            if rest.isEmpty {
                results.append(candidate)
            } else if status.kind == .directory {
                results += match(rest, under: candidate)
            }
        }
        return results
    }

    static func isPattern(_ component: String) -> Bool {
        component.contains("*") || component.contains("?") || component.contains("[")
    }

    /// `fnmatch(3)` with `FNM_PERIOD`, so `*` does not match a leading dot,
    /// as in Ruby's `Dir.glob`.
    static func matches(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, FNM_PERIOD) == 0
    }

    /// `a{b,c}d` as `abd` and `acd`. Braces do not nest in any cask MacUp has
    /// seen; a pattern with nested or unbalanced braces is kept whole, and
    /// then matches only a file with those characters in its name.
    static func braces(_ pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "{"),
              let close = pattern[open...].firstIndex(of: "}"),
              !pattern[pattern.index(after: open)..<close].contains("{")
        else { return [pattern] }
        let head = pattern[..<open]
        let tail = String(pattern[pattern.index(after: close)...])
        return pattern[pattern.index(after: open)..<close]
            .split(separator: ",", omittingEmptySubsequences: false)
            .flatMap { braces(head + $0 + tail) }
    }
}
