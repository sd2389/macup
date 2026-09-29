import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

/// The app's Show What Depends on It, run against the real Homebrew provider
/// on a pretend Mac: a fake runner that answers only what it was told, a fake
/// file system, and a throwaway home directory.
@MainActor
@Suite("App: what depends on an item")
struct AppModelDependentsTests {
    @MainActor
    final class Machine {
        let home: TemporaryDirectory
        let runner = FakeCommandRunner()
        let fileSystem = FakeFileSystem()
        let model: AppModel

        init(uses: FakeCommandRunner.Response = .success("aws-c-auth\nkrb5\n")) throws {
            home = try TemporaryDirectory(prefix: "macup-app-dependents")
            fileSystem.addExecutable("/opt/homebrew/bin/brew")
            runner.register("brew", ["--version"], .success("Homebrew 7.0.6\n"))
            runner.register("brew", ["--prefix"], .success("/opt/homebrew\n"))
            runner.register("brew", ["outdated", "--json=v2"], .success("""
                {"formulae": [{"name": "git", "installed_versions": ["2.43.0"], "current_version": "2.44.0", "pinned": false},
                              {"name": "mysql", "installed_versions": ["9.7.1"], "current_version": "26.7.0_2", "pinned": false}],
                 "casks": []}
                """))
            runner.register("brew", ["info", "--json=v2", "--installed"], .success("""
                {"formulae": [{"name": "git", "full_name": "git", "installed": [{"version": "2.43.0", "installed_on_request": true}], "linked_keg": "2.43.0"},
                              {"name": "mysql", "full_name": "mysql", "installed": [{"version": "9.7.1", "installed_on_request": true}], "linked_keg": "9.7.1"}],
                 "casks": []}
                """))
            runner.register("brew", ["uses", "--installed", "--formula", "mysql"], uses)
            runner.register("brew", ["uses", "--installed", "--cask", "mysql"], .success())
            let providers: [any UpdateProvider] = [HomebrewProvider()]
            model = AppModel(environment: AppEnvironment(
                runner: runner,
                fileSystem: fileSystem,
                authorizer: FakeBiometricAuthorizer(capability: .touchID),
                checkEngine: CheckEngine(providers: providers),
                planner: UpdatePlanner(providers: []),
                makeExecutionEngine: { paths in
                    ExecutionEngine(providers: [], history: HistoryStore(paths: paths), configurationStore: ConfigurationStore(paths: paths))
                },
                doctorEngine: DoctorEngine(providers: providers, checks: []),
                faceCamera: FakeFaceCamera(),
                loginShell: FakeLoginShell(),
                homeDirectory: home.canonicalPath,
                processEnvironment: [:],
                system: SystemInfo(productVersion: "15.0", buildVersion: "24A335", architecture: "arm64"),
                bundledExecutablePath: nil
            ))
        }

        /// Waits until the fake runner has been asked `brew uses`, so a test
        /// can act while the question is in flight.
        func waitForQuestion() async throws {
            while !runner.recordedRequests.contains(where: { $0.arguments.first == "uses" }) {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    let mysql = try! PackageID(.brew, "mysql")

    @Test("The question is offered only for what MacUp can ask about")
    func offeredOnlyWhereItCanAnswer() async throws {
        let machine = try Machine()
        await machine.model.checkNow()
        #expect(machine.model.canListDependents(of: mysql))
        #expect(!machine.model.canListDependents(of: try PackageID(.brewCask, "firefox")))
        #expect(!machine.model.canListDependents(of: try PackageID(.npm, "typescript")))
        #expect(!machine.runner.recordedRequests.contains { $0.arguments.first == "uses" }, "a check never asks")
    }

    @Test("Asking shows progress, then the answer, and reuses the check's Homebrew")
    func asks() async throws {
        let machine = try Machine()
        await machine.model.checkNow()
        machine.model.showDependents(of: mysql)
        #expect(machine.model.dependents.runningItem == mysql)
        let task = try #require(machine.model.dependents.task)
        await task.value

        let report = try #require(machine.model.dependents.reports[mysql])
        #expect(report.outcome == .listed)
        #expect(report.dependents?.map(\.rawValue) == ["brew:aws-c-auth", "brew:krb5"])
        #expect(machine.model.dependents.runningItem == nil)
        #expect(machine.model.dependents.task == nil)
        #expect(machine.runner.recordedRequests.filter { $0.arguments == ["--version"] }.count == 1, "nothing detected twice")
        #expect(machine.runner.recordedRequests.allSatisfy { $0.effect == .readOnly })
    }

    @Test("Cancel stops the question, and the answer says it was stopped")
    func cancel() async throws {
        let machine = try Machine(uses: FakeCommandRunner.Response(standardOutput: "krb5\n", delay: .seconds(30)))
        await machine.model.checkNow()
        machine.model.showDependents(of: mysql)
        let task = try #require(machine.model.dependents.task)
        try await machine.waitForQuestion()

        // One question at a time: asking about another item meanwhile does nothing.
        machine.model.showDependents(of: try PackageID(.brew, "git"))
        #expect(machine.model.dependents.runningItem == mysql)

        machine.model.cancelDependents()
        await task.value
        #expect(machine.model.dependents.reports[mysql]?.outcome == .cancelled)
        #expect(machine.model.dependents.reports[mysql]?.dependents == nil)
        #expect(machine.model.dependents.runningItem == nil)
    }

    @Test("A failed answer is kept with its reason, never shown as nothing")
    func failure() async throws {
        let machine = try Machine(uses: .exit(1, standardError: "Error: broken\n"))
        await machine.model.checkNow()
        machine.model.showDependents(of: mysql)
        await machine.model.dependents.task?.value
        let report = try #require(machine.model.dependents.reports[mysql])
        #expect(report.outcome == .failed)
        #expect(report.dependents == nil)
        #expect(report.error?.message.contains("`brew uses` failed") == true)
    }
}
