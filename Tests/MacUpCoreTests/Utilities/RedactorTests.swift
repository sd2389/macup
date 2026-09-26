import Testing

@testable import MacUpCore

// Token-shaped dummies are assembled at runtime so secret scanners do not flag this file.
private let dummyStripeKey = "sk_" + "live_" + "DUMMY0000000000000000000000"
private let dummyGoogleKey = "AI" + "za" + "DUMMY000000000000000000000000000000"

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
            // Shapes a TOML parse error can quote from a hand-edited [env] table.
            ("3 | PASSWORD = dummy horse battery", "3 | PASSWORD = <redacted>"),
            ("3 | DB_PASSWORD = \"dummyvalue1234", "3 | DB_PASSWORD = <redacted>"),
            ("3 | STRIPE_KEY = \(dummyStripeKey)", "3 | STRIPE_KEY = <redacted>"),
            ("DB_PASS=dummyvalue1234", "DB_PASS=<redacted>"),
            ("SENTRY_DSN=dummy-dsn-value", "SENTRY_DSN=<redacted>"),
            ("{\"password\": \"dummyvalue1234\"}", "{\"password\": <redacted>}"),
            ("https://0123456789abcdef0123456789abcdef01234567@github.com/org/repo.git", "https://<redacted>@github.com/org/repo.git"),
            ("leaked \(dummyStripeKey) here", "leaked <redacted> here"),
            ("maps \(dummyGoogleKey) here", "maps <redacted> here"),
            ("line one\npassword = dummy value\nline three", "line one\npassword = <redacted>\nline three"),
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
