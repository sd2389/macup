/// Strings from docs/TEST_PLAN.md "Security tests": spaces, quotes, semicolons,
/// `$()`, backticks, newlines, Unicode, leading dashes, and friends.
public enum HostileInput {
    /// Package-name-shaped strings that must only ever travel as single,
    /// verbatim arguments.
    public static let names: [String] = [
        "pkg with spaces",
        "quote\"double",
        "quote'single",
        "semi;colon",
        "pkg; rm -rf ~",
        "$(touch /tmp/macup-should-not-exist)",
        "`id`",
        "${HOME}",
        "pkg && echo pwned",
        "pkg | cat /etc/passwd",
        "pkg > /tmp/out",
        "new\nline",
        "tab\tseparated",
        "back\\slash",
        "glob*?[abc]",
        "~",
        "--force",
        "-rf",
        "ünïcødé-名前-🚀",
        "\u{1B}[31mred",
        "\u{202E}evil",
    ]

    /// Names MacUp must refuse to turn into a package identity.
    public static let unrepresentableNames: [String] = [
        "",
        "new\nline",
        "tab\tseparated",
        "\u{1B}[31mred",
        "\u{202E}evil",
        "--force",
        "-rf",
        " leading-space",
        "trailing-space ",
        "nul\u{0}byte",
    ]
}
