import Darwin
import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// A pretend Mac for the scan: nothing is installed until a test says so,
/// and no command is answered unless a test registers it.
private final class ScanMac: @unchecked Sendable {
    let runner = FakeCommandRunner()
    let fileSystem = FakeFileSystem()
    var environment = [
        "HOME": "/Users/example",
        "PATH": "/opt/homebrew/bin:/Users/example/.local/bin:/usr/bin:/bin",
    ]

    var checkEnvironment: CheckEnvironment {
        CheckEnvironment(
            runner: runner,
            fileSystem: fileSystem,
            processEnvironment: environment,
            homeDirectory: "/Users/example",
            system: SystemInfo(productVersion: "27.0", buildVersion: "26A428", architecture: "arm64"),
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
    }
}

@Suite("Every package manager on this Mac")
struct ToolScanTests {
    private func tool(_ id: String) -> KnownTool {
        KnownTool.catalog.first { $0.id == id }!
    }

    @Test("What is installed is found and asked for its version; what MacUp manages is said so")
    func findsManagedAndUnmanagedTools() async {
        let mac = ScanMac()
        mac.fileSystem
            .addExecutable("/opt/homebrew/bin/brew")
            .addExecutable("/Users/example/.local/bin/pipx")
        mac.runner.register("brew", ["--version"], .success("Homebrew 7.0.6\n"))
        mac.runner.register("pipx", ["--version"], .success("1.7.1\n"))

        let scan = await ToolScanner(catalog: [tool("homebrew"), tool("pipx"), tool("macports")])
            .scan(environment: mac.checkEnvironment)

        #expect(scan.managed.map(\.id) == ["homebrew"])
        #expect(scan.managed.first?.version == "Homebrew 7.0.6")
        #expect(scan.managed.first?.tool.managedBy == .homebrew)
        #expect(scan.unmanaged.map(\.id) == ["pipx"])
        #expect(scan.unmanaged.first?.version == "1.7.1")
        #expect(scan.unmanaged.first?.path == "/Users/example/.local/bin/pipx")
        #expect(scan.absent.map(\.id) == ["macports"], "what is not installed is named, not silently dropped")
    }

    @Test("A tool installed several times says where the other copies are")
    func listsOtherInstallations() async {
        let mac = ScanMac()
        mac.fileSystem
            .addExecutable("/opt/homebrew/bin/uv")
            .addExecutable("/Users/example/.local/bin/uv")
        mac.runner.register("uv", ["--version"], .success("uv 0.9.2\n"))

        let scan = await ToolScanner(catalog: [tool("uv")]).scan(environment: mac.checkEnvironment)

        let found = try! #require(scan.found.first)
        #expect(found.path == "/opt/homebrew/bin/uv", "the PATH order decides which copy MacUp would use")
        #expect(found.otherPaths == ["/Users/example/.local/bin/uv"])
    }

    @Test("A copy in a location someone else could write is reported and never run")
    func refusesAnUntrustedCopy() async {
        let mac = ScanMac()
        mac.environment["PATH"] = "/usr/bin"
        mac.fileSystem
            .addExecutable("/opt/local/bin/port")
            .setOwnership("/opt/local/bin/port", FileOwnership(uid: getuid() + 501, gid: 20, mode: 0o777))

        let scan = await ToolScanner(catalog: [tool("macports")]).scan(environment: mac.checkEnvironment)

        let found = try! #require(scan.found.first)
        #expect(found.version == nil)
        #expect(found.note?.contains("will not run this copy") == true)
        #expect(mac.runner.recordedRequests.isEmpty, "nothing was run")
    }

    @Test("A version command that fails leaves the tool listed, with the reason instead of a version")
    func reportsAFailedVersionCommand() async {
        let mac = ScanMac()
        mac.fileSystem.addExecutable("/opt/homebrew/bin/pnpm")
        mac.runner.register("pnpm", ["--version"], .exit(1, standardError: "broken\n"))

        let scan = await ToolScanner(catalog: [tool("pnpm")]).scan(environment: mac.checkEnvironment)

        let found = try! #require(scan.found.first)
        #expect(found.path == "/opt/homebrew/bin/pnpm")
        #expect(found.version == nil)
        #expect(found.note?.contains("failed") == true)
    }

    @Test("A tool that is only a shell function is found by its file, and nothing is run for it")
    func findsAShellFunctionByItsFile() async {
        let mac = ScanMac()
        mac.fileSystem.addFile("/Users/example/.nvm/nvm.sh", contents: "# nvm")

        let scan = await ToolScanner(catalog: [tool("nvm")]).scan(environment: mac.checkEnvironment)

        let found = try! #require(scan.found.first)
        #expect(found.path == "/Users/example/.nvm/nvm.sh")
        #expect(found.version == nil)
        #expect(found.note?.contains("shell function") == true)
        #expect(mac.runner.recordedRequests.isEmpty)
    }

    @Test("The scan can run nothing but the version commands on the allowlist")
    func refusesACommandThatIsNotAVersionQuery() async {
        let mac = ScanMac()
        mac.fileSystem.addExecutable("/opt/homebrew/bin/brew")
        mac.runner.register("brew", ["upgrade"], .success("upgraded\n"))
        let hostile = KnownTool(
            id: "hostile",
            displayName: "Hostile",
            executable: "brew",
            versionArguments: ["upgrade"],
            standardLocations: ["/opt/homebrew/bin/brew"],
            kind: .packageManager,
            manages: "Nothing"
        )

        let scan = await ToolScanner(catalog: [hostile]).scan(environment: mac.checkEnvironment)

        let found = try! #require(scan.found.first)
        #expect(found.version == nil)
        #expect(found.note?.contains("could not read the version") == true)
        #expect(mac.runner.recordedRequests.isEmpty, "the read-only guard refused it before it could run")
    }

    @Test("Every catalog entry that runs a command has that command on the read-only allowlist")
    func everyVersionCommandIsAllowlisted() {
        for tool in KnownTool.catalog where !tool.versionArguments.isEmpty {
            let request = CommandRequest(
                executable: URL(fileURLWithPath: "/usr/local/bin/" + tool.executable),
                arguments: tool.versionArguments,
                environment: [:],
                effect: .readOnly
            )
            #expect(
                CommandAllowlist.toolScan.contains { $0.matches(request) },
                "\(tool.displayName) would be refused by the read-only guard"
            )
        }
    }

    @Test("Catalog entries are distinct, and only the four providers are marked as managed")
    func catalogIsConsistent() {
        let ids = KnownTool.catalog.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(KnownTool.catalog.filter { $0.managedBy != nil }.compactMap(\.managedBy).sorted() == ProviderID.known.sorted())
        #expect(KnownTool.unmanaged.allSatisfy { $0.managedBy == nil })
        #expect(
            KnownTool.catalog.allSatisfy { !$0.versionArguments.contains { $0.hasPrefix("-") && $0 != "--version" } },
            "a version query takes no other option"
        )
    }

    @Test("Version output is one line, made safe to show, with the home directory hidden")
    func versionLineIsSafe() {
        #expect(ToolScanner.versionLine("", homeDirectory: "/Users/example") == nil)
        #expect(ToolScanner.versionLine("\n\n1.2.3\nmore\n", homeDirectory: "/Users/example") == "1.2.3")
        #expect(
            ToolScanner.versionLine("pip 26.0 from /Users/example/lib/pip\n", homeDirectory: "/Users/example")
                == "pip 26.0 from ~/lib/pip"
        )
        let escape = ToolScanner.versionLine("1.0\u{1B}[31m\n", homeDirectory: "/Users/example")
        #expect(escape?.contains("\u{1B}") == false)
        let long = ToolScanner.versionLine(String(repeating: "v", count: 300), homeDirectory: "/Users/example")
        #expect(long?.count == 100)
    }
}
