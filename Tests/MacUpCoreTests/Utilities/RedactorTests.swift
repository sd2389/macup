import Testing

@testable import MacUpCore

@Suite("Redactor")
struct RedactorTests {
    let redactor = Redactor()

    @Test(
        "Secrets are removed",
        arguments: [
            ("https://alice:s3cret@proxy.example.com:8080", "https://<redacted>@proxy.example.com:8080"),
            ("Authorization: Bearer abcdef123456", "Authorization: <redacted>"),
            ("curl -H 'authorization: token abcdef123456'", "curl -H 'authorization: <redacted>'"),
            ("using bearer abcdefghijklmnop", "using bearer <redacted>"),
            ("//registry.npmjs.org/:_authToken=npm_abcdefghijklmnopqrstuvwxyz0123456789", "//registry.npmjs.org/:_authToken=<redacted>"),
            ("GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789", "GITHUB_TOKEN=<redacted>"),
            ("HOMEBREW_GITHUB_API_TOKEN=abc123", "HOMEBREW_GITHUB_API_TOKEN=<redacted>"),
            ("password: hunter2", "password: <redacted>"),
            ("token ghp_abcdefghijklmnopqrstuvwxyz0123456789 leaked", "token <redacted> leaked"),
            ("key AKIAABCDEFGHIJKLMNOP here", "key <redacted> here"),
            ("sk-ant-abcdefghijklmnopqrstuvwxyz", "<redacted>"),
            ("xoxb-1234567890-abcdefghij", "<redacted>"),
        ]
    )
    func redactsSecrets(input: String, expected: String) {
        #expect(redactor.redact(input) == expected)
    }

    @Test(
        "Ordinary provider output is unchanged",
        arguments: [
            "Homebrew 4.4.2",
            "git 2.43.0 -> 2.44.0",
            "npm error code ENOENT",
            "Warning: No available formula with the name \"gti\".",
            "/opt/homebrew/bin/brew outdated --json=v2",
        ]
    )
    func leavesOrdinaryTextAlone(input: String) {
        #expect(redactor.redact(input) == input)
    }

    @Test("The home directory can be abbreviated")
    func abbreviatesHome() {
        let redactor = Redactor(homeDirectory: "/Users/example/")
        #expect(redactor.redact("lstat '/Users/example/.local/lib'") == "lstat '~/.local/lib'")
        #expect(PathDisplay.abbreviatingHome("/Users/example", homeDirectory: "/Users/example") == "~")
        #expect(PathDisplay.abbreviatingHome("/Users/examples/x", homeDirectory: "/Users/example") == "/Users/examples/x")
    }
}
