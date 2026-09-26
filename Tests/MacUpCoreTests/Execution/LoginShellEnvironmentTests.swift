import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Login shell environment", .timeLimit(.minutes(1)))
struct LoginShellEnvironmentTests {
    private let nonce = "0123abcd"
    private var begin: String { LoginShellEnvironment.beginMarker(nonce) }
    private var end: String { LoginShellEnvironment.endMarker(nonce) }

    private func output(_ parts: [String]) -> Data {
        Data(parts.joined().utf8)
    }

    @Test("Parses the environment between the markers, ignoring startup noise")
    func parse() throws {
        let data = output([
            "Last login: Fri Sep 25\nwelcome!\n",
            begin,
            "PATH=/Users/example/.homebrew/bin:/usr/bin\u{0}",
            "EQUALS=a=b=c\u{0}",
            "MULTILINE=one\ntwo\u{0}",
            "1BAD=x\u{0}", "bad-name=x\u{0}", "no separator\u{0}",
            end,
            "\nlogout\n",
        ])
        let environment = try LoginShellEnvironment.parse(data, nonce: nonce)
        #expect(environment == [
            "PATH": "/Users/example/.homebrew/bin:/usr/bin",
            "EQUALS": "a=b=c",
            "MULTILINE": "one\ntwo",
        ])
    }

    @Test("Missing markers or a missing PATH are errors, not guesses")
    func parseFailures() {
        #expect(throws: MacUpError.self) { try LoginShellEnvironment.parse(Data("no markers\n".utf8), nonce: nonce) }
        #expect(throws: MacUpError.self) {
            try LoginShellEnvironment.parse(self.output([self.begin, "HOME=/h\u{0}"]), nonce: self.nonce)
        }
        #expect(throws: MacUpError.self) {
            try LoginShellEnvironment.parse(self.output([self.begin, "HOME=/h\u{0}", self.end]), nonce: self.nonce)
        }
        // Markers from another run (or echoed script text) are not accepted.
        #expect(throws: MacUpError.self) {
            try LoginShellEnvironment.parse(
                self.output([LoginShellEnvironment.beginMarker("other"), "PATH=/x\u{0}", LoginShellEnvironment.endMarker("other")]),
                nonce: self.nonce
            )
        }
    }

    @Test("Only known shell families get a script")
    func scripts() {
        for shell in ["/bin/zsh", "/bin/bash", "/bin/sh", "/opt/homebrew/bin/fish"] {
            let script = LoginShellEnvironment.script(for: shell, nonce: nonce)
            #expect(script != nil, "\(shell)")
            #expect(script?.contains(begin) == false, "the finished marker must not appear in the script")
        }
        #expect(LoginShellEnvironment.script(for: "/bin/tcsh", nonce: nonce) == nil)
        #expect(LoginShellEnvironment.script(for: "/usr/local/bin/nu", nonce: nonce) == nil)
    }

    @Test("The shell runs as an interactive login shell in the home directory")
    func invocation() async throws {
        let directory = try TemporaryDirectory()
        // A stand-in "zsh" that records how it was called, prints startup
        // noise that echoes its arguments, then runs the script with /bin/sh.
        let shell = try directory.makeScript(
            "zsh",
            "printf '%s %s %s' \"$1\" \"$2\" \"$3\" > '\(directory.path)/args'\n"
                + "/bin/pwd -P > '\(directory.path)/pwd'\n"
                + "echo \"noise: $*\"\n"
                + "exec /bin/sh -c \"$4\""
        )
        let environment = try await LoginShellEnvironment.capture(
            shell: shell.path,
            runner: ProcessCommandRunner(),
            homeDirectory: directory.path,
            baseEnvironment: ["HOME": directory.path, "SECRET_TOKEN": "not-passed"]
        )
        #expect(environment["PATH"] == SearchPath.system.joined(separator: ":"))
        #expect(environment["SHELL"] == shell.path)
        #expect(environment["SECRET_TOKEN"] == nil, "only the base allowlist reaches the probe")
        #expect(try String(contentsOf: directory.appending("args"), encoding: .utf8) == "-l -i -c")
        #expect(try String(contentsOf: directory.appending("pwd"), encoding: .utf8).trimmingCharacters(in: .newlines) == directory.canonicalPath)
    }

    @Test("Real zsh: .zshrc is read and prompt hooks run, as in a terminal")
    func realZsh() async throws {
        let home = try TemporaryDirectory()
        try """
            export PATH="/from/zshrc:$PATH"
            macup_test_hook() { export PATH="/from/precmd:$PATH" }
            precmd_functions+=(macup_test_hook)
            echo "noise from zshrc"
            """.write(to: home.appending(".zshrc"), atomically: true, encoding: .utf8)
        let environment = try await LoginShellEnvironment.capture(
            shell: "/bin/zsh",
            runner: ProcessCommandRunner(),
            homeDirectory: home.path,
            baseEnvironment: ["HOME": home.path, "USER": "example"]
        )
        let path = try #require(environment["PATH"])
        #expect(path.hasPrefix("/from/precmd:/from/zshrc:"), "\(path)")
        #expect(environment["MACUP_RESOLVING_ENVIRONMENT"] == "1")
        #expect(environment["TERM"] == "dumb")
    }

    @Test("The login shell comes from the account database and /etc/shells")
    func userLoginShell() {
        let shell = LoginShellEnvironment.userLoginShell()
        #expect(shell.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: shell))
    }
}
