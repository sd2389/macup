import Foundation

/// Removes secrets from text before it is logged, displayed, stored in
/// history, or exported.
///
/// Redaction is deliberately over-eager: losing a harmless value is
/// acceptable, leaking a credential is not. It is a defense in depth, not a
/// license to log raw environments or command output.
public struct Redactor: Sendable, Hashable {
    public static let placeholder = "<redacted>"

    /// When set, occurrences of this path are replaced with `~`, keeping
    /// usernames out of exported diagnostics.
    public var homeDirectory: String?

    public init(homeDirectory: String? = nil) {
        self.homeDirectory = homeDirectory
    }

    public func redact(_ text: String) -> String {
        var result = text
        for rule in Self.rules {
            result = rule.apply(to: result)
        }
        if let homeDirectory {
            result = PathDisplay.abbreviatingHome(in: result, homeDirectory: homeDirectory)
        }
        return result
    }

    private struct Rule: @unchecked Sendable {
        // NSRegularExpression is immutable and documented as thread-safe.
        let expression: NSRegularExpression
        let template: String

        init(_ pattern: String, template: String, options: NSRegularExpression.Options = []) {
            // The patterns are compile-time constants; failure is a programming error.
            // swiftlint:disable:next force_try
            expression = try! NSRegularExpression(pattern: pattern, options: options)
            self.template = template
        }

        func apply(to text: String) -> String {
            let range = NSRange(text.startIndex..., in: text)
            return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
    }

    private static let secretName =
        "(?:token|secret|passw(?:or)?d|pwd|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|_auth|auth[_-]?token|credentials?)"

    private static let rules: [Rule] = [
        // user:password@ in URLs (proxies, registries, git remotes).
        Rule(#"([A-Za-z][A-Za-z0-9+.\-]*://)[^\s/:@]+:[^\s/@]+@"#, template: "$1\(placeholder)@"),
        // HTTP authorization headers.
        Rule(#"(authorization\s*[:=]\s*)(?:(?:bearer|basic|token)\s+)?[^\s'"]+"#, template: "$1\(placeholder)", options: [.caseInsensitive]),
        // Bearer tokens anywhere.
        Rule(#"\b(bearer\s+)[A-Za-z0-9._~+/=\-]{8,}"#, template: "$1\(placeholder)", options: [.caseInsensitive]),
        // NAME=value / NAME: value where NAME looks secret (npm `_authToken=`, `GITHUB_TOKEN=`...).
        Rule(
            #"([A-Za-z0-9_.\-/:]*"# + secretName + #"[A-Za-z0-9_.\-]*\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s"',;]+)"#,
            template: "$1\(placeholder)",
            options: [.caseInsensitive]
        ),
        // Well-known token formats, even without a telling variable name.
        Rule(#"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#, template: placeholder),
        Rule(#"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#, template: placeholder),
        Rule(#"\bglpat-[A-Za-z0-9_\-]{20,}\b"#, template: placeholder),
        Rule(#"\bnpm_[A-Za-z0-9]{30,}\b"#, template: placeholder),
        Rule(#"\bAKIA[0-9A-Z]{16}\b"#, template: placeholder),
        Rule(#"\bxox[abprs]-[A-Za-z0-9\-]{10,}\b"#, template: placeholder),
        Rule(#"\bsk-[A-Za-z0-9_\-]{20,}\b"#, template: placeholder),
    ]
}

/// Helpers for showing paths to people.
public enum PathDisplay {
    /// Replaces a leading home directory with `~` (`/Users/me/x` → `~/x`).
    public static func abbreviatingHome(_ path: String, homeDirectory: String) -> String {
        let home = standardized(homeDirectory)
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Replaces every occurrence of the home directory inside free text.
    public static func abbreviatingHome(in text: String, homeDirectory: String) -> String {
        let home = standardized(homeDirectory)
        guard !home.isEmpty, home != "/" else { return text }
        return text
            .replacingOccurrences(of: home + "/", with: "~/")
            .replacingOccurrences(of: home, with: "~")
    }

    static func standardized(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
