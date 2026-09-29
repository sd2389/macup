import Darwin
import Foundation

/// Launches commands with Foundation `Process`.
///
/// - The executable is launched directly with an argument array; no shell is
///   involved, so arguments are never interpreted.
/// - The child receives exactly `request.environment` and reads stdin from
///   `/dev/null`, so it can never block on an interactive prompt.
/// - stdout and stderr are captured separately, bounded by `outputLimit`, and
///   optionally streamed.
/// - A read-only command is stopped on timeout or task cancellation: SIGTERM,
///   then SIGKILL after `terminationGracePeriod`.
/// - A command that changes the machine is never killed part-way. Cancelling
///   only keeps it from starting; once it is running it is left to finish,
///   and the caller stops before the next one. On timeout it receives SIGINT,
///   exactly what Ctrl+C at a terminal sends and what package managers are
///   written to recover from, and MacUp waits for it to exit. Stopping
///   Homebrew between unlinking the old version and linking the new one is
///   how a formula ends up with neither on PATH.
public struct ProcessCommandRunner: CommandRunning {
    public var terminationGracePeriod: Duration
    /// How long to wait for output pipes to close after the process exits.
    /// A grandchild process can keep a pipe open; MacUp stops waiting rather
    /// than hang, and marks the output as truncated.
    public var outputDrainTimeout: Duration

    public init(
        terminationGracePeriod: Duration = .seconds(3),
        outputDrainTimeout: Duration = .seconds(2)
    ) {
        self.terminationGracePeriod = terminationGracePeriod
        self.outputDrainTimeout = outputDrainTimeout
    }

    public func run(_ request: CommandRequest, output: CommandOutputHandler?) async throws -> CommandResult {
        try request.validate()
        let execution = ProcessExecution(
            request: request,
            outputHandler: output,
            gracePeriod: terminationGracePeriod,
            drainTimeout: outputDrainTimeout
        )
        return try await withTaskCancellationHandler {
            try await execution.run()
        } onCancel: {
            if request.effect == .readOnly {
                execution.stop(.cancelled)
            } else {
                execution.preventLaunch()
            }
        }
    }
}

/// One launch of one process. All mutable state is guarded by `lock`.
private final class ProcessExecution: @unchecked Sendable {
    enum StopReason {
        case cancelled
        case timedOut
    }

    private enum Phase {
        case idle
        case running
        case exited
    }

    private let request: CommandRequest
    private let outputHandler: CommandOutputHandler?
    private let gracePeriod: Duration
    private let drainTimeout: Duration
    private let process = Process()
    private let lock = NSLock()
    private var phase = Phase.idle
    private var stopReason: StopReason?

    init(
        request: CommandRequest,
        outputHandler: CommandOutputHandler?,
        gracePeriod: Duration,
        drainTimeout: Duration
    ) {
        self.request = request
        self.outputHandler = outputHandler
        self.gracePeriod = gracePeriod
        self.drainTimeout = drainTimeout
    }

    private var displayCommand: String {
        Redactor().redact(request.invocation.displayString)
    }

    func run() async throws -> CommandResult {
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.workingDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError

        let stdoutCollector = OutputCollector(stream: .standardOutput, limit: request.outputLimit, handler: outputHandler)
        let stderrCollector = OutputCollector(stream: .standardError, limit: request.outputLimit, handler: outputHandler)
        stdoutCollector.start(reading: standardOutput.fileHandleForReading)
        stderrCollector.start(reading: standardError.fileHandleForReading)

        let timeout = request.timeout
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.stop(.timedOut)
        }
        defer { timeoutTask.cancel() }

        let startedAt = Date()
        let termination: CommandTermination
        do {
            termination = try await launchAndWaitForExit()
        } catch {
            stdoutCollector.abandon()
            stderrCollector.abandon()
            throw error
        }

        let stdoutComplete = await stdoutCollector.waitForEnd(timeout: drainTimeout)
        let stderrComplete = await stderrCollector.waitForEnd(timeout: drainTimeout)
        let finishedAt = Date()
        let stdout = stdoutCollector.snapshot()
        let stderr = stderrCollector.snapshot()

        switch lock.withLock({ stopReason }) {
        case .cancelled:
            throw MacUpError(.cancelled, "The command was cancelled.", command: displayCommand)
        case .timedOut:
            throw MacUpError(
                .timeout,
                request.effect == .readOnly
                    ? "The command did not finish within \(Self.describe(timeout)) and was stopped."
                    : "The command did not finish within \(Self.describe(timeout)), so MacUp interrupted it the way Ctrl+C would and waited for it to exit.",
                detail: TextExcerpt.tail(of: String(decoding: stderr.data, as: UTF8.self)),
                command: displayCommand,
                recoverySuggestion: "Check your network connection or run the command yourself to see why it is slow."
            )
        case nil:
            return CommandResult(
                invocation: request.invocation,
                effect: request.effect,
                termination: termination,
                standardOutput: stdout.data,
                standardError: stderr.data,
                outputTruncated: stdout.truncated || stderr.truncated || !stdoutComplete || !stderrComplete,
                startedAt: startedAt,
                finishedAt: finishedAt
            )
        }
    }

    private func launchAndWaitForExit() async throws -> CommandTermination {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [self] process in
                let termination: CommandTermination = process.terminationReason == .uncaughtSignal
                    ? .signaled(process.terminationStatus)
                    : .exited(process.terminationStatus)
                lock.withLock { phase = .exited }
                continuation.resume(returning: termination)
            }

            lock.lock()
            if let stopReason {
                lock.unlock()
                process.terminationHandler = nil
                let error = stopReason == .cancelled
                    ? MacUpError(.cancelled, "The command was cancelled before it started.", command: displayCommand)
                    : MacUpError(.timeout, "The command timed out before it started.", command: displayCommand)
                continuation.resume(throwing: error)
                return
            }
            do {
                try process.run()
                phase = .running
                lock.unlock()
            } catch {
                lock.unlock()
                process.terminationHandler = nil
                continuation.resume(throwing: MacUpError(
                    .commandFailed,
                    "Could not launch \(request.executable.path).",
                    detail: (error as NSError).localizedDescription,
                    command: displayCommand
                ))
            }
        }
    }

    /// Keeps a command that has not started from starting, and leaves one that
    /// is running alone. How a cancelled run treats a command that changes the
    /// machine.
    func preventLaunch() {
        lock.withLock {
            if phase == .idle && stopReason == nil { stopReason = .cancelled }
        }
    }

    /// Stops the process. A read-only command gets SIGTERM now and SIGKILL
    /// after the grace period. Anything else gets SIGINT and is waited for,
    /// however long it takes to put itself back together.
    func stop(_ reason: StopReason) {
        lock.lock()
        guard phase != .exited, stopReason == nil else {
            lock.unlock()
            return
        }
        stopReason = reason
        let isRunning = phase == .running
        lock.unlock()
        guard isRunning else { return }

        guard request.effect == .readOnly else {
            process.interrupt()
            return
        }
        process.terminate()
        let gracePeriod = gracePeriod
        Task { [weak self] in
            try? await Task.sleep(for: gracePeriod)
            self?.killIfStillRunning()
        }
    }

    private func killIfStillRunning() {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .running else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    static func describe(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        if seconds == seconds.rounded() { return "\(Int(seconds)) seconds" }
        return String(format: "%.1f seconds", seconds)
    }
}

/// Reads one pipe until EOF, keeping at most `limit` bytes.
private final class OutputCollector: @unchecked Sendable {
    private let stream: CommandOutputStream
    private let limit: Int
    private let handler: CommandOutputHandler?
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false
    private var finished = false
    private var reachedEndOfFile = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var handle: FileHandle?

    init(stream: CommandOutputStream, limit: Int, handler: CommandOutputHandler?) {
        self.stream = stream
        self.limit = limit
        self.handler = handler
    }

    func start(reading handle: FileHandle) {
        lock.withLock { self.handle = handle }
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.finish(complete: true)
            } else {
                self.append(chunk)
            }
        }
    }

    private func append(_ chunk: Data) {
        lock.withLock {
            let remaining = limit - data.count
            if remaining > 0 { data.append(chunk.prefix(remaining)) }
            if chunk.count > remaining { truncated = true }
        }
        handler?(CommandOutputChunk(stream: stream, data: chunk))
    }

    private func finish(complete: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        reachedEndOfFile = complete
        if !complete { truncated = true }
        let pending = waiters
        waiters.removeAll()
        let handle = handle
        lock.unlock()
        if !complete { handle?.readabilityHandler = nil }
        pending.forEach { $0.resume() }
    }

    /// Stops reading without waiting for EOF.
    func abandon() {
        finish(complete: false)
    }

    private func waitUntilFinished() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Waits for EOF. Returns `false` if the stream had to be abandoned.
    func waitForEnd(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitUntilFinished()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let finishedFirst = await group.next() ?? false
            if !finishedFirst { abandon() }
            group.cancelAll()
            return lock.withLock { reachedEndOfFile }
        }
    }

    func snapshot() -> (data: Data, truncated: Bool) {
        lock.withLock { (data, truncated) }
    }
}
