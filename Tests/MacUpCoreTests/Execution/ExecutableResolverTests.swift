import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("ExecutableResolver")
struct ExecutableResolverTests {
    @Test("The first executable on the search path wins")
    func searchPathOrder() {
        let fileSystem = FakeFileSystem()
            .addExecutable("/Users/example/.homebrew/bin/brew")
            .addExecutable("/opt/homebrew/bin/brew")
        let resolver = ExecutableResolver(fileSystem: fileSystem)
        let search = ExecutableSearch(
            name: "brew",
            searchPath: ["/Users/example/.local/bin", "/Users/example/.homebrew/bin", "/opt/homebrew/bin"],
            standardLocations: ["/opt/homebrew/bin/brew"]
        )
        #expect(resolver.resolve(search) == .found(ResolvedExecutable(
            path: "/Users/example/.homebrew/bin/brew",
            canonicalPath: "/Users/example/.homebrew/bin/brew",
            source: .searchPath
        )))
    }

    @Test("Directories and non-executable files are skipped")
    func skipsNonExecutables() {
        let fileSystem = FakeFileSystem()
            .addDirectory("/first/npm")
            .addFile("/second/npm")
            .addExecutable("/third/npm")
        let resolver = ExecutableResolver(fileSystem: fileSystem)
        let result = resolver.resolve(ExecutableSearch(name: "npm", searchPath: ["/first", "/second", "/third"]))
        guard case .found(let executable) = result else {
            Issue.record("Expected to find /third/npm, got \(result)")
            return
        }
        #expect(executable.path == "/third/npm")
    }

    @Test("Standard locations are used when the search path has nothing")
    func standardLocationFallback() {
        let fileSystem = FakeFileSystem().addExecutable("/usr/local/bin/brew")
        let resolver = ExecutableResolver(fileSystem: fileSystem)
        let result = resolver.resolve(ExecutableSearch(
            name: "brew",
            searchPath: ["/usr/bin"],
            standardLocations: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        ))
        guard case .found(let executable) = result else {
            Issue.record("Expected a standard-location hit, got \(result)")
            return
        }
        #expect(executable.source == .standardLocation)
        #expect(executable.path == "/usr/local/bin/brew")
    }

    @Test("Symlinks are recorded with their canonical target")
    func recordsCanonicalPath() {
        let fileSystem = FakeFileSystem()
            .addSymlink("/Users/example/.local/bin/npm", to: "/Users/example/.hermes/node/bin/npm")
            .addExecutable("/Users/example/.hermes/node/bin/npm")
        let resolver = ExecutableResolver(fileSystem: fileSystem)
        guard case .found(let executable) = resolver.resolve(
            ExecutableSearch(name: "npm", searchPath: ["/Users/example/.local/bin"])
        ) else {
            Issue.record("Expected to resolve npm")
            return
        }
        #expect(executable.path == "/Users/example/.local/bin/npm")
        #expect(executable.canonicalPath == "/Users/example/.hermes/node/bin/npm")
        #expect(executable.directory == "/Users/example/.local/bin")
        #expect(executable.canonicalDirectory == "/Users/example/.hermes/node/bin")
    }

    @Test("A valid configured path wins over the search path")
    func configuredPathWins() {
        let fileSystem = FakeFileSystem()
            .addExecutable("/opt/homebrew/bin/brew")
            .addExecutable("/custom/bin/brew")
        let resolver = ExecutableResolver(fileSystem: fileSystem)
        let result = resolver.resolve(ExecutableSearch(
            name: "brew",
            configuredPath: "/custom/bin/brew",
            searchPath: ["/opt/homebrew/bin"]
        ))
        guard case .found(let executable) = result else {
            Issue.record("Expected the configured path, got \(result)")
            return
        }
        #expect(executable.source == .configured)
        #expect(executable.path == "/custom/bin/brew")
    }

    @Test(
        "An unusable configured path fails closed instead of falling back",
        arguments: ["relative/brew", "/custom/bin/not-brew", "/missing/bin/brew"]
    )
    func invalidConfiguredPathFailsClosed(configuredPath: String) {
        let fileSystem = FakeFileSystem()
            .addExecutable("/opt/homebrew/bin/brew")
            .addExecutable("/custom/bin/not-brew")
        let resolver = ExecutableResolver(fileSystem: fileSystem)
        let result = resolver.resolve(ExecutableSearch(
            name: "brew",
            configuredPath: configuredPath,
            searchPath: ["/opt/homebrew/bin"]
        ))
        guard case .invalidConfiguredPath(let path, _) = result else {
            Issue.record("Expected invalidConfiguredPath, got \(result)")
            return
        }
        #expect(path == configuredPath)
    }

    @Test("Not found lists what was searched")
    func notFound() {
        let resolver = ExecutableResolver(fileSystem: FakeFileSystem())
        let result = resolver.resolve(ExecutableSearch(
            name: "mise",
            searchPath: ["/usr/bin"],
            standardLocations: ["/opt/homebrew/bin/mise"]
        ))
        #expect(result == .notFound(searched: ["/usr/bin", "/opt/homebrew/bin"]))
    }

    @Test("Names that could escape a directory are rejected", arguments: ["", "../brew", "bin/brew", ".", ".."])
    func rejectsPathLikeNames(name: String) {
        let fileSystem = FakeFileSystem().addExecutable("/usr/bin/brew")
        let resolver = ExecutableResolver(fileSystem: fileSystem)
        #expect(resolver.resolve(ExecutableSearch(name: name, searchPath: ["/usr/bin"])) == .notFound(searched: []))
    }

    @Test("Installations are de-duplicated by canonical path, in priority order")
    func installationsDeduplicate() {
        let fileSystem = FakeFileSystem()
            .addExecutable("/opt/homebrew/bin/brew")
            .addSymlink("/usr/local/bin/brew", to: "../Homebrew/bin/brew")
            .addExecutable("/usr/local/Homebrew/bin/brew")
        let resolver = ExecutableResolver(fileSystem: fileSystem)
        let installations = resolver.installations(ExecutableSearch(
            name: "brew",
            searchPath: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/Homebrew/bin"],
            standardLocations: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        ))
        #expect(installations.map(\.path) == ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
        #expect(installations.map(\.canonicalPath) == ["/opt/homebrew/bin/brew", "/usr/local/Homebrew/bin/brew"])
    }
}
