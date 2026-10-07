/// Makes untrusted text safe to print to a terminal.
///
/// Provider output (package names, versions, descriptions, error messages) is
/// untrusted input. Printed verbatim, escape sequences could rewrite the
/// user's terminal and bidirectional-override characters could make text read
/// differently than it is. Every such character is replaced by a visible
/// `\u{…}` escape so nothing is hidden.
public enum TerminalText {
    public static func sanitize(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isUnsafe) else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            if isUnsafe(scalar) {
                result += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// `json` with every scalar that could act on a terminal written as a
    /// `\uXXXX` escape.
    ///
    /// JSONEncoder escapes only C0 controls. DEL, C1 controls, bidirectional
    /// overrides, and line/paragraph separators can still act on a terminal
    /// the output is printed to. JSONEncoder emits such scalars only inside
    /// string literals, so this is lossless for JSON readers; C0 (including
    /// the newlines of pretty-printing) is left alone.
    public static func escapingUnsafeScalars(inJSON json: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in json.unicodeScalars {
            if scalar.value >= 0x20 && (isUnsafe(scalar) || scalar.value == 0x2028 || scalar.value == 0x2029) {
                result.append(contentsOf: String(format: "\\u%04x", scalar.value).unicodeScalars)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// Whether printing `scalar` could control the terminal or disguise text.
    public static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F:
            // C0 controls (including ESC, newline, tab), DEL, and C1 controls.
            return true
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            // Bidirectional marks, embeddings, overrides, and isolates.
            return true
        default:
            return false
        }
    }
}

/// Short, display-safe excerpts of command output for error messages.
public enum TextExcerpt {
    static let maxLineCharacters = 1_000

    /// Returns the last `maxLines` non-empty lines of `text`, redacted and
    /// capped at `maxCharacters`, or `nil` when there is nothing to show.
    public static func tail(
        of text: String,
        maxLines: Int = 12,
        maxCharacters: Int = 2_000,
        redactor: Redactor = Redactor()
    ) -> String? {
        // Over-long lines are cut before redaction, which keeps the regular
        // expressions' cost bounded; the dropped tail is never shown.
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingTrailingWhitespace() }
            .filter { !$0.isEmpty }
            .map { $0.count > maxLineCharacters ? String($0.prefix(maxLineCharacters)) + "…" : $0 }
        guard !lines.isEmpty else { return nil }
        var excerpt = lines.suffix(maxLines).joined(separator: "\n")
        excerpt = redactor.redact(excerpt)
        if excerpt.count > maxCharacters {
            excerpt = "…" + excerpt.suffix(maxCharacters - 1)
        }
        return excerpt
    }
}

extension Substring {
    fileprivate func trimmingTrailingWhitespace() -> String {
        var view = self
        while let last = view.last, last.isWhitespace { view.removeLast() }
        return String(view)
    }
}

/// Counting and padding in words, where one sentence has to read correctly
/// for one item and for many.
///
/// One implementation, in the one module both surfaces import: the CLI's
/// renderers, the explanation text, and the app all had their own before,
/// and four pluralizers is three too many.
public enum TextCount {
    public static func plural(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count) " + (count == 1 ? singular : plural ?? singular + "s")
    }

    public static func pad(_ text: String, to width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
