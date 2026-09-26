import Testing

@testable import MacUpCore

@Suite("MacUpPaths")
struct MacUpPathsTests {
    @Test("Standard paths follow the documented scheme")
    func standardPaths() throws {
        let paths = try MacUpPaths.resolve(homeDirectory: "/Users/example/", environment: [:])
        #expect(paths.configFile == "/Users/example/.config/macup/config.json")
        #expect(paths.stateDirectory == "/Users/example/.local/state/macup")
        #expect(paths.historyFile == "/Users/example/.local/state/macup/history.jsonl")
        #expect(paths.configDirectorySource == .standard)
    }

    @Test("XDG variables do not move MacUp's files (the app would not see them)")
    func ignoresXDG() throws {
        let paths = try MacUpPaths.resolve(
            homeDirectory: "/Users/example",
            environment: ["XDG_CONFIG_HOME": "/elsewhere", "XDG_STATE_HOME": "/elsewhere"]
        )
        #expect(paths.configDirectory == "/Users/example/.config/macup")
    }

    @Test("Absolute overrides are honored and labelled")
    func overrides() throws {
        let paths = try MacUpPaths.resolve(
            homeDirectory: "/Users/example",
            environment: ["MACUP_CONFIG_DIR": "/tmp/macup-config/", "MACUP_STATE_DIR": "/tmp/macup-state"]
        )
        #expect(paths.configFile == "/tmp/macup-config/config.json")
        #expect(paths.stateDirectory == "/tmp/macup-state")
        #expect(paths.configDirectorySource == .environment)
        #expect(paths.stateDirectorySource == .environment)
    }

    @Test("A relative override is rejected rather than guessed", arguments: ["relative/dir", "./x", "~/macup"])
    func rejectsRelativeOverride(value: String) {
        let error = #expect(throws: MacUpError.self) {
            try MacUpPaths.resolve(homeDirectory: "/Users/example", environment: ["MACUP_CONFIG_DIR": value])
        }
        #expect(error?.kind == .configurationInvalid)
    }
}
