import MacUpCore

/// Minimal ANSI styling, used only when ``CLIContext/allowsStyling`` is true.
/// Styling is decoration: every state is also stated in words.
struct TextStyle {
    let enabled: Bool
    let homeDirectory: String

    func bold(_ text: String) -> String {
        enabled ? "\u{1B}[1m" + text + "\u{1B}[0m" : text
    }

    func dim(_ text: String) -> String {
        enabled ? "\u{1B}[2m" + text + "\u{1B}[0m" : text
    }

    /// Untrusted text made safe for the terminal.
    func safe(_ text: String) -> String {
        TerminalText.sanitize(text)
    }

    /// A path, abbreviated with `~` and made terminal-safe.
    func path(_ path: String) -> String {
        TerminalText.sanitize(PathDisplay.abbreviatingHome(path, homeDirectory: homeDirectory))
    }

    /// Free text that may contain paths under the home directory.
    func text(_ text: String) -> String {
        TerminalText.sanitize(PathDisplay.abbreviatingHome(in: text, homeDirectory: homeDirectory))
    }

    static func pad(_ text: String, to width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func plural(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count) " + (count == 1 ? singular : plural ?? singular + "s")
    }
}
