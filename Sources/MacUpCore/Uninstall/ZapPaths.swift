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

    /// Whether every wildcard in `pattern` is tied to one app, so that what
    /// it matches is that app's rather than whatever a shared folder holds.
    ///
    /// Leading folders many apps share are passed over first: the home
    /// folder's standard folders, `~/Library` and each folder directly in it,
    /// `Preferences/ByHost`, `Logs/DiagnosticReports`,
    /// `Application Support/CrashReporter`, and Apple's own `com.apple.…`
    /// folders. The next name must then be literal —
    /// `~/Library/Caches/Firefox/*` — or a wildcard whose literal start names
    /// the app: one of `owners` (the cask token, the app's name or bundle
    /// identifier), or a reverse-DNS name of at least three parts, as in
    /// `com.microsoft.VSCode*`. `~/Library/Preferences/*` and
    /// `~/Library/Caches/*.plist` are not tied to anything.
    ///
    /// Only patterns in the home folder are judged here; the removal
    /// boundary refuses everything outside it anyway.
    func isAnchored(_ pattern: String, owners: [String]) -> Bool {
        // "Redis Insight" and redis-insight also name RedisInsight.
        let owners = owners.flatMap { owner in
            [owner.lowercased(), owner.lowercased().filter { !" -_".contains($0) }]
        }.filter { $0.count >= 3 }
        for alternative in Self.braces(pattern) {
            let relative: Substring
            if alternative.hasPrefix("~/") {
                relative = alternative.dropFirst(2)
            } else if alternative.hasPrefix(homeDirectory + "/") {
                relative = alternative.dropFirst(homeDirectory.count + 1)
            } else {
                continue
            }
            var shared = ""
            for component in relative.split(separator: "/").map(String.init) {
                guard Self.isPattern(component) else {
                    let path = shared.isEmpty ? component : shared + "/" + component
                    if Self.isShared(path) {
                        shared = path
                        continue
                    }
                    break
                }
                let literal = String(component.prefix { !"*?[".contains($0) }).lowercased()
                let reverseDNS = literal.split(separator: ".").count >= 3
                guard reverseDNS || owners.contains(where: literal.hasPrefix) else { return false }
                break
            }
        }
        return true
    }

    /// Folders under the home folder that hold many apps' files, by their
    /// path relative to it.
    static func isShared(_ relative: String) -> Bool {
        let components = relative.split(separator: "/")
        if components.first == "Library", components.count <= 2 { return true }
        if ["Library/Preferences/ByHost", "Library/Logs/DiagnosticReports", "Library/Application Support/CrashReporter"]
            .contains(relative) {
            return true
        }
        if components.count > 1, components.last?.lowercased().hasPrefix("com.apple.") == true { return true }
        return RemovalBoundary.standardHomeFolders.contains(relative)
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
