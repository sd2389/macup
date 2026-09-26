import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// End to end with real processes: the real `ProcessCommandRunner`, real
/// file system, and real check engine, pointed at stub executables in a
/// temporary directory. The stubs print fixture output and log every
/// invocation, so the test proves the whole chain — resolution, environment,
/// arguments, parsing — without any real package manager.
@Suite("Integration with stub provider executables", .timeLimit(.minutes(1)))
struct StubProviderIntegrationTests {
    private struct Sandbox {
        let root: TemporaryDirectory
        var bin: String { root.path + "/bin" }
        var home: String { root.path + "/home" }
        var log: String { root.path + "/invocations.log" }
        var globalRoot: String { root.path + "/lib/node_modules" }

        init() throws {
            root = try TemporaryDirectory(prefix: "macup-stubs")
            for directory in [bin, home, globalRoot] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
        }

        /// Writes a stub that logs `name args…` and dispatches on its arguments.
        func stub(_ name: String, cases: [(pattern: String, body: String)]) throws {
            var script = "printf '%s\\n' \"\(name) $*\" >> '\(log)'\ncase \"$*\" in\n"
            for (pattern, body) in cases {
                script += "  '\(pattern)') \(body) ;;\n"
            }
            script += "  *) printf 'unexpected: %s\\n' \"$*\" >&2; exit 99 ;;\nesac\n"
            let url = URL(fileURLWithPath: bin + "/" + name)
            try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func cat(_ fixture: String) throws -> String {
            "/bin/cat '\(try Fixture.url(fixture).path)'"
        }
    }

    @Test("A full check against stubs runs only read-only commands and parses everything")
    func fullCheck() async throws {
        let sandbox = try Sandbox()
        try sandbox.stub("brew", cases: [
            ("--version", "printf 'Homebrew 7.0.6\\n'"),
            ("--prefix", "printf '%s\\n' '\(sandbox.root.path)'"),
            ("outdated --json=v2", "/usr/bin/env > '\(sandbox.root.path)/brew-env.txt'; " + (try sandbox.cat("homebrew/outdated-formula.json"))),
            ("info --json=v2 --installed", try sandbox.cat("homebrew/info-installed.json")),
        ])
        try sandbox.stub("node", cases: [("--version", "printf 'v24.19.0\\n'")])
        let npmOutdated = """
            {"typescript": {"current": "5.4.2", "wanted": "5.9.3", "latest": "5.9.3", "location": "\(sandbox.globalRoot)/typescript"}}
            """
        try sandbox.stub("npm", cases: [
            ("--version", "printf '11.17.0\\n'"),
            ("prefix -g", "printf '%s\\n' '\(sandbox.root.path)'"),
            ("root -g", "printf '%s\\n' '\(sandbox.globalRoot)'"),
            ("outdated -g --json", "printf '%s\\n' '\(npmOutdated)'; printf '%s\\n' \"$PATH\" > '\(sandbox.root.path)/npm-path.txt'; exit 1"),
            ("ls -g --json --depth=0", "printf '%s\\n' '{\"dependencies\": {\"typescript\": {\"version\": \"5.4.2\"}}}'"),
        ])
        try sandbox.stub("mise", cases: [
            ("--version", "printf '2026.7.3 macos-arm64 (2026-07-08)\\n'; printf 'mise WARN new version\\n' >&2"),
            ("outdated --json", "/bin/pwd -P > '\(sandbox.root.path)/mise-cwd.txt'; " + (try sandbox.cat("mise/outdated-global-fuzzy.json"))),
            ("ls --json", try sandbox.cat("mise/ls.json")),
        ])
        try sandbox.stub("softwareupdate", cases: [("--list --no-scan", try sandbox.cat("macos/list-one-update.txt"))])

        let engine = CheckEngine(providers: [
            HomebrewProvider(standardLocations: []),
            NpmProvider(standardLocations: []),
            MiseProvider(standardLocations: []),
            MacOSProvider(softwareUpdatePath: sandbox.bin + "/softwareupdate"),
        ])
        let environment = CheckEnvironment(
            runner: ProcessCommandRunner(),
            fileSystem: LocalFileSystem(),
            processEnvironment: [
                "HOME": sandbox.home,
                "PATH": sandbox.bin,
                "MACUP_TEST_SECRET": "must-not-reach-providers",
                "HOMEBREW_NO_ANALYTICS": "1",
            ],
            homeDirectory: sandbox.home,
            system: SystemInfo(productVersion: "27.0", buildVersion: "26A428", architecture: "arm64")
        )
        let loaded = LoadedConfiguration(configuration: .defaults, source: .defaults, path: sandbox.home + "/.config/macup/config.json")
        let report = await engine.run(configuration: loaded, environment: environment)

        #expect(report.providers.map(\.availability) == [.available, .available, .available, .available], "\(report.providers.map(\.errors))")
        #expect(!report.hasProviderErrors, "\(report.providers.flatMap(\.errors))")
        #expect(report.updates.map(\.id.rawValue) == [
            "brew:git", "brew:mysql", "npm:typescript", "mise:node", "mise:python", "macos:macOS 27.2 Beta-26B5091g",
        ])
        #expect(report.providers.map(\.installedCount) == [6, 1, 3, nil])

        // Exactly the allowlisted, read-only invocations reached the stubs.
        let invocations = try String(contentsOfFile: sandbox.log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(Set(invocations) == [
            "brew --version", "brew --prefix", "brew outdated --json=v2", "brew info --json=v2 --installed",
            "node --version", "npm --version", "npm prefix -g", "npm root -g",
            "npm outdated -g --json", "npm ls -g --json --depth=0",
            "mise --version", "mise outdated --json", "mise ls --json",
            "softwareupdate --list --no-scan",
        ])
        #expect(report.commands.count == invocations.count)
        #expect(report.commands.allSatisfy { $0.effect == .readOnly })

        // Environment and working-directory guarantees, observed from inside the stubs.
        let brewEnvironment = try String(contentsOfFile: sandbox.root.path + "/brew-env.txt", encoding: .utf8)
        #expect(brewEnvironment.contains("HOMEBREW_NO_AUTO_UPDATE=1"))
        #expect(brewEnvironment.contains("HOMEBREW_NO_ANALYTICS=1"))
        #expect(!brewEnvironment.contains("MACUP_TEST_SECRET"))
        let npmPath = try String(contentsOfFile: sandbox.root.path + "/npm-path.txt", encoding: .utf8)
        #expect(npmPath.hasPrefix(sandbox.bin + ":"))
        let miseDirectory = try String(contentsOfFile: sandbox.root.path + "/mise-cwd.txt", encoding: .utf8)
        #expect(miseDirectory.trimmingCharacters(in: .newlines) == sandbox.root.canonicalPath + "/home")
    }

    @Test("A stub that fails is reported, and the other providers still complete")
    func failingStub() async throws {
        let sandbox = try Sandbox()
        try sandbox.stub("brew", cases: [
            ("--version", "printf 'Homebrew 7.0.6\\n'"),
            ("--prefix", "printf '/opt/homebrew\\n'"),
            ("outdated --json=v2", "printf 'Error: GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123 rejected\\n' >&2; exit 1"),
            ("info --json=v2 --installed", "printf '{\"formulae\": [], \"casks\": []}\\n'"),
        ])
        try sandbox.stub("softwareupdate", cases: [("--list --no-scan", "printf 'No new software available.\\n' >&2")])
        let engine = CheckEngine(providers: [
            HomebrewProvider(standardLocations: []),
            MacOSProvider(softwareUpdatePath: sandbox.bin + "/softwareupdate"),
        ])
        let environment = CheckEnvironment(
            runner: ProcessCommandRunner(),
            fileSystem: LocalFileSystem(),
            processEnvironment: ["HOME": sandbox.home, "PATH": sandbox.bin],
            homeDirectory: sandbox.home,
            system: SystemInfo(productVersion: "27.0", buildVersion: nil, architecture: "arm64")
        )
        let report = await engine.run(
            configuration: LoadedConfiguration(configuration: .defaults, source: .defaults, path: "/nonexistent"),
            environment: environment
        )
        let failure = try #require(report.providers[0].errors.first)
        #expect(failure.operation == .outdated)
        #expect(failure.error.exitStatus == 1)
        #expect(failure.error.detail == "Error: GITHUB_TOKEN=<redacted> rejected")
        #expect(report.providers[1].updateCount == 0)
        #expect(report.providers[1].errors.isEmpty)
    }
}
