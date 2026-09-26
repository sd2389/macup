import Foundation
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
        arguments: ["relative/brew", "/custom/bin/not-brew", "/missing/bin/brew", " /custom/bin/brew", "/custom/bin/brew ", "", "   "]
    )
    func invalidConfiguredPathFailsClosed(configuredPath: String) {
        let fileSystem = FakeFileSystem()
            .addExecutable("/opt/homebrew/bin/brew")
            .addExecutable("/custom/bin/brew")
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

    @Test(
        "A standard location someone else could modify is not run implicitly",
        arguments: [
            ("/opt/homebrew/bin/brew", FileOwnership(uid: getuid() &+ 1, gid: 20, mode: 0o755)),
            ("/opt/homebrew/bin", FileOwnership(uid: getuid(), gid: 20, mode: 0o775)),
            ("/opt/homebrew", FileOwnership(uid: 0, gid: 0, mode: 0o777)),
        ]
    )
    func untrustedStandardLocation(path: String, ownership: FileOwnership) {
        let fileSystem = FakeFileSystem().addExecutable("/opt/homebrew/bin/brew").setOwnership(path, ownership)
        let resolver = ExecutableResolver(fileSystem: fileSystem)
        let result = resolver.resolve(ExecutableSearch(name: "brew", searchPath: ["/usr/bin"], standardLocations: ["/opt/homebrew/bin/brew"]))
        guard case .untrustedLocation(let found, let reason) = result else {
            Issue.record("Expected untrustedLocation, got \(result)")
            return
        }
        #expect(found == "/opt/homebrew/bin/brew")
        #expect(reason.contains(path))
    }

    @Test("Standard locations owned by root or the user, or group-writable only by admin, are used; PATH is never second-guessed")
    func trustedLocations() {
        let fileSystem = FakeFileSystem()
            .addExecutable("/opt/homebrew/bin/brew")
            .setOwnership("/opt/homebrew/bin", FileOwnership(uid: getuid(), gid: 80, mode: 0o775))
            .setOwnership("/opt/homebrew", FileOwnership(uid: 0, gid: 0, mode: 0o755))
            .addExecutable("/shared/bin/mise")
            .setOwnership("/shared/bin", FileOwnership(uid: getuid() &+ 1, gid: 20, mode: 0o777))
        let resolver = ExecutableResolver(fileSystem: fileSystem)
        let brew = resolver.resolve(ExecutableSearch(name: "brew", searchPath: ["/usr/bin"], standardLocations: ["/opt/homebrew/bin/brew"]))
        #expect(brew == .found(ResolvedExecutable(path: "/opt/homebrew/bin/brew", canonicalPath: "/opt/homebrew/bin/brew", source: .standardLocation)))
        let mise = resolver.resolve(ExecutableSearch(name: "mise", searchPath: ["/shared/bin"]))
        #expect(mise == .found(ResolvedExecutable(path: "/shared/bin/mise", canonicalPath: "/shared/bin/mise", source: .searchPath)))
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
