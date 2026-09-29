import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// Exercises the real `ProcessCommandRunner` with harmless system binaries and
/// throwaway scripts. No provider binary is ever launched.
@Suite("ProcessCommandRunner", .timeLimit(.minutes(1)))
struct ProcessCommandRunnerTests {
    let runner = ProcessCommandRunner(
        terminationGracePeriod: .milliseconds(300),
        outputDrainTimeout: .milliseconds(500)
    )

    private func request(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String] = ["PATH": "/usr/bin:/bin"],
        timeout: Duration = .seconds(20),
        outputLimit: Int = 1 << 20,
        effect: CommandEffect = .readOnly
    ) -> CommandRequest {
        CommandRequest(
            executable: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            effect: effect,
            outputLimit: outputLimit
        )
    }

    @Test("Each argument reaches the process verbatim, never through a shell")
    func passesArgumentsVerbatim() async throws {
        let result = try await runner.run(request("/usr/bin/printf", [#"%s\0"#] + HostileInput.names))
        #expect(result.succeeded)
        var received = result.standardOutputText.components(separatedBy: "\0")
        #expect(received.removeLast() == "")
        #expect(received == HostileInput.names)
    }

    @Test("Shell syntax in arguments is inert")
    func shellSyntaxIsInert() async throws {
        let directory = try TemporaryDirectory()
        let marker = directory.appending("pwned").path
        let payloads = [
            "$(touch \(marker))",
            "`touch \(marker)`",
            "; touch \(marker)",
            "| touch \(marker)",
            "&& touch \(marker)",
            "\ntouch \(marker)",
        ]
        let result = try await runner.run(request("/bin/echo", payloads))
        #expect(result.succeeded)
        #expect(result.standardOutputText == payloads.joined(separator: " ") + "\n")
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("stdout and stderr are captured separately; non-zero exit is a result, not an error")
    func capturesStreamsAndExitStatus() async throws {
        let directory = try TemporaryDirectory()
        let script = try directory.makeScript("streams", "echo out\necho err >&2\nexit 3")
        let result = try await runner.run(request(script.path))
        #expect(result.exitStatus == 3)
        #expect(!result.succeeded)
        #expect(result.standardOutputText == "out\n")
        #expect(result.standardErrorText == "err\n")
        #expect(result.finishedAt >= result.startedAt)
        #expect(result.invocation == CommandInvocation(executable: script.path, arguments: []))
    }

    @Test("The child receives exactly the requested environment")
    func usesExactEnvironment() async throws {
        let environment = ["MACUP_TEST_VALUE": "a b;c", "PATH": "/usr/bin:/bin"]
        let result = try await runner.run(request("/usr/bin/env", environment: environment))
        let lines = Set(result.standardOutputText.split(separator: "\n").map(String.init))
        #expect(lines == ["MACUP_TEST_VALUE=a b;c", "PATH=/usr/bin:/bin"])
    }

    @Test("The working directory is honored")
    func usesWorkingDirectory() async throws {
        let directory = try TemporaryDirectory()
        var pwd = request("/bin/pwd", ["-P"])
        pwd.workingDirectory = directory.url
        let result = try await runner.run(pwd)
        #expect(result.standardOutputText.trimmingCharacters(in: .newlines) == directory.canonicalPath)
    }

    @Test("stdin is /dev/null, so a prompt can never block")
    func standardInputIsNull() async throws {
        let result = try await runner.run(request("/bin/cat", timeout: .seconds(10)))
        #expect(result.succeeded)
        #expect(result.standardOutput.isEmpty)
    }

    @Test("A command that runs too long is stopped and reported as a timeout")
    func timesOut() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let error = await #expect(throws: MacUpError.self) {
            try await runner.run(request("/bin/sleep", ["30"], timeout: .milliseconds(200)))
        }
        #expect(error?.kind == .timeout)
        #expect(clock.now - start < .seconds(10))
    }

    @Test("A process that ignores SIGTERM is killed after the grace period")
    func killsProcessIgnoringTerminate() async throws {
        let directory = try TemporaryDirectory()
        let script = try directory.makeScript("stubborn", "trap '' TERM\nexec /bin/sleep 30")
        let clock = ContinuousClock()
        let start = clock.now
        let error = await #expect(throws: MacUpError.self) {
            try await runner.run(request(script.path, timeout: .milliseconds(200)))
        }
        #expect(error?.kind == .timeout)
        #expect(clock.now - start < .seconds(10))
    }

    @Test("Cancelling the task stops the process")
    func cancellationStopsProcess() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let runner = runner
        let sleep = request("/bin/sleep", ["30"])
        let task = Task { try await runner.run(sleep) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let error = await #expect(throws: MacUpError.self) { try await task.value }
        #expect(error?.kind == .cancelled)
        #expect(clock.now - start < .seconds(10))
    }

    @Test("Cancelling never stops a command that changes the machine: it is left to finish")
    func cancellationLetsAModifyingCommandFinish() async throws {
        let directory = try TemporaryDirectory()
        let marker = directory.appending("finished").path
        // Stands in for a package manager part-way through an install.
        let script = try directory.makeScript("install", "/bin/sleep 1\ntouch '\(marker)'\necho installed")
        let runner = runner
        let install = request(script.path, effect: .modifying)
        let task = Task { try await runner.run(install) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = try await task.value
        #expect(result.succeeded)
        #expect(result.standardOutputText.contains("installed"))
        #expect(FileManager.default.fileExists(atPath: marker), "the command ran to the end")
    }

    @Test("A command that changes the machine never starts once the run is cancelled")
    func cancelledModifyingCommandNeverLaunches() async throws {
        let directory = try TemporaryDirectory()
        let marker = directory.appending("launched").path
        let script = try directory.makeScript("marker", "touch '\(marker)'")
        let runner = runner
        let touch = request(script.path, effect: .modifying)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(touch)
        }
        let error = await #expect(throws: MacUpError.self) { try await task.value }
        #expect(error?.kind == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("A command that changes the machine and runs too long is interrupted, and allowed to clean up")
    func timedOutModifyingCommandIsInterruptedNotKilled() async throws {
        let directory = try TemporaryDirectory()
        let marker = directory.appending("cleaned-up").path
        // Its cleanup takes longer than the grace period, which is exactly
        // what a SIGKILL would cut short.
        let script = try directory.makeScript(
            "slow-cleanup",
            "trap 'kill $! 2>/dev/null; /bin/sleep 1; touch \"\(marker)\"; exit 130' INT\n/bin/sleep 30 &\nwait"
        )
        let error = await #expect(throws: MacUpError.self) {
            try await runner.run(request(script.path, timeout: .milliseconds(300), effect: .modifying))
        }
        #expect(error?.kind == .timeout)
        #expect(error?.message.contains("interrupted it the way Ctrl+C would") == true)
        #expect(FileManager.default.fileExists(atPath: marker), "the cleanup ran to the end")
    }

    @Test("A task that is already cancelled never launches the process")
    func alreadyCancelledNeverLaunches() async throws {
        let directory = try TemporaryDirectory()
        let marker = directory.appending("launched").path
        let script = try directory.makeScript("marker", "touch '\(marker)'")
        let runner = runner
        let touch = request(script.path)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(touch)
        }
        let error = await #expect(throws: MacUpError.self) { try await task.value }
        #expect(error?.kind == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("A missing executable is a launch failure")
    func missingExecutable() async throws {
        let error = await #expect(throws: MacUpError.self) {
            try await runner.run(request("/nonexistent/macup-test-tool"))
        }
        #expect(error?.kind == .commandFailed)
    }

    @Test("Requests that cannot be launched faithfully are refused before launch")
    func refusesInvalidRequests() async throws {
        let relative = CommandRequest(executable: try #require(URL(string: "echo")), effect: .readOnly)
        let withNul = request("/bin/echo", ["safe", "bad\u{0}arg"])
        var badEnvironment = request("/bin/echo")
        badEnvironment.environment["BAD=NAME"] = "x"

        for invalid in [relative, withNul, badEnvironment] {
            let error = await #expect(throws: MacUpError.self) { try await runner.run(invalid) }
            #expect(error?.kind == .commandFailed)
            #expect(error?.message.hasPrefix("MacUp refused") == true)
        }
    }

    @Test("Output beyond the limit is dropped and marked truncated")
    func truncatesOutput() async throws {
        let result = try await runner.run(
            request("/bin/dd", ["if=/dev/zero", "bs=1000", "count=100"], outputLimit: 1_000)
        )
        #expect(result.standardOutput.count == 1_000)
        #expect(result.outputTruncated)
    }

    @Test("Output can be streamed while the command runs")
    func streamsOutput() async throws {
        let collected = LockedData()
        let result = try await runner.run(request("/usr/bin/printf", ["line1\nline2\n"])) { chunk in
            if chunk.stream == .standardOutput { collected.append(chunk.data) }
        }
        #expect(collected.value == result.standardOutput)
        #expect(result.standardOutputText == "line1\nline2\n")
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    var value: Data { lock.withLock { data } }
}
