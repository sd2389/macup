import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

/// The Providers screen's "Also on This Mac": the same read-only scan the
/// CLI runs, against a pretend Mac.
@MainActor
@Suite("App: every package manager on this Mac")
struct AppModelToolScanTests {
    @MainActor
    final class Machine {
        let home: TemporaryDirectory
        let runner = FakeCommandRunner()
        let fileSystem = FakeFileSystem()
        let model: AppModel

        init() throws {
            home = try TemporaryDirectory(prefix: "macup-app-tools")
            fileSystem
                .addExecutable("/opt/homebrew/bin/brew")
                .addExecutable("/opt/homebrew/bin/pipx")
            runner.register("brew", ["--version"], .success("Homebrew 7.0.6\n"))
            runner.register("pipx", ["--version"], .success("1.7.1\n"))
            model = AppModel(environment: AppEnvironment(
                runner: runner,
                fileSystem: fileSystem,
                authorizer: FakeBiometricAuthorizer(capability: .touchID),
                checkEngine: CheckEngine(providers: []),
                planner: UpdatePlanner(providers: []),
                makeExecutionEngine: { paths in
                    ExecutionEngine(providers: [], history: HistoryStore(paths: paths), configurationStore: ConfigurationStore(paths: paths))
                },
                doctorEngine: DoctorEngine(providers: [], checks: []),
                faceCamera: FakeFaceCamera(),
                loginShell: FakeLoginShell(),
                homeDirectory: home.canonicalPath,
                processEnvironment: ["PATH": "/opt/homebrew/bin"],
                system: SystemInfo(productVersion: "15.0", buildVersion: "24A335", architecture: "arm64"),
                bundledExecutablePath: nil
            ))
        }

        func finishScan() async throws {
            let task = try #require(model.tools.task)
            await task.value
        }
    }

    @Test("The screen scans once, lists what MacUp does not manage, and says nothing is proposed for it")
    func scansOnce() async throws {
        let machine = try Machine()
        machine.model.scanToolsIfNeeded()
        #expect(machine.model.isScanningTools)
        try await machine.finishScan()

        #expect(machine.model.unmanagedTools.map(\.id) == ["pipx"])
        #expect(machine.model.unmanagedTools.first?.version == "1.7.1")
        #expect(machine.model.tools.scan?.managed.map(\.id) == ["homebrew"], "Homebrew is listed as managed, not as other")
        #expect(!machine.model.isScanningTools)

        // Opening the screen again does not scan again.
        machine.model.scanToolsIfNeeded()
        #expect(machine.model.tools.task == nil)
        #expect(machine.runner.recordedRequests.filter { $0.arguments == ["--version"] }.count == 2)
    }

    @Test("Scan Again scans again, and the scan only ever reads")
    func scanAgain() async throws {
        let machine = try Machine()
        machine.model.scanTools()
        try await machine.finishScan()
        machine.model.scanTools()
        try await machine.finishScan()

        #expect(machine.runner.recordedRequests.count == 4)
        #expect(machine.runner.recordedRequests.allSatisfy { $0.effect == .readOnly })
        #expect(machine.runner.recordedRequests.allSatisfy { $0.arguments == ["--version"] })
    }
}
