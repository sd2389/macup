import Testing

@testable import MacUpCore

@Suite("TerminalText")
struct TerminalTextTests {
    @Test("Escape sequences, newlines, and bidi overrides become visible escapes")
    func escapesUnsafeCharacters() {
        #expect(TerminalText.sanitize("\u{1B}[2Jcleared") == #"\u{1B}[2Jcleared"#)
        #expect(TerminalText.sanitize("line\nbreak") == #"line\u{A}break"#)
        #expect(TerminalText.sanitize("abc\u{202E}fed") == #"abc\u{202E}fed"#)
        #expect(TerminalText.sanitize("c1\u{9B}31m") == #"c1\u{9B}31m"#)
    }

    @Test("Ordinary Unicode is untouched")
    func keepsOrdinaryText() {
        let text = "ünïcødé 名前 🚀 → git@2.44"
        #expect(TerminalText.sanitize(text) == text)
    }

    @Test("Excerpts keep the tail, redact, and skip blank lines")
    func excerpts() {
        let text = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n\nGITHUB_TOKEN=abc\n"
        let excerpt = TextExcerpt.tail(of: text, maxLines: 3)
        #expect(excerpt == "line 19\nline 20\nGITHUB_TOKEN=<redacted>")
        #expect(TextExcerpt.tail(of: " \n\n") == nil)
    }
}
