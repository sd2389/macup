import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("CommandInvocation display")
struct CommandInvocationTests {
    @Test("Plain arguments are shown as-is")
    func plainArguments() {
        let invocation = CommandInvocation(executable: "/opt/homebrew/bin/brew", arguments: ["upgrade", "python@3.12"])
        #expect(invocation.displayString == "/opt/homebrew/bin/brew upgrade python@3.12")
    }

    @Test("Arguments needing quotes are single-quoted")
    func quotedArguments() {
        let invocation = CommandInvocation(
            executable: "/usr/local/bin/npm",
            arguments: ["install", "-g", "@scope/pkg name", "it's", "", "$(id)"]
        )
        #expect(invocation.displayString == #"/usr/local/bin/npm install -g '@scope/pkg name' 'it'\''s' '' '$(id)'"#)
    }

    @Test("Control characters use ANSI-C quoting so they are visible")
    func controlCharacters() {
        let invocation = CommandInvocation(executable: "/bin/echo", arguments: ["a\nb", "\u{1B}[31m", "\u{202E}x", "q'\\"])
        let backslash = "\\"
        let expected = "/bin/echo $'a\\nb' $'\\x1B[31m' $'" + backslash + "u202Ex' 'q'\\''\\'"
        #expect(invocation.displayString == expected)
    }

    @Test("No hostile name produces raw control characters in display output")
    func hostileNamesAreVisible() {
        for name in HostileInput.names {
            let display = CommandInvocation(executable: "/bin/echo", arguments: [name]).displayString
            #expect(!display.unicodeScalars.contains(where: TerminalText.isUnsafe), "\(display)")
            #expect(display.hasPrefix("/bin/echo "))
        }
    }
}
