import Darwin
import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import macup

@Suite("Cancelling a command")
struct CancellationTests {
    @Test("The first Ctrl+C cancels the work in progress instead of killing the process")
    func firstInterruptCancels() async throws {
        // Ignore the signal for the length of this test as well. MacUp does
        // the same thing while it is handling interrupts; doing it here too
        // means the signal cannot reach the default action in the moment
        // before MacUp's own handler is installed.
        let previous = signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, previous) }

        let cancelled = await Interruption.run(handlingInterrupts: true) { () -> Bool in
            // Sent from inside the work, so it can never arrive after the
            // handler has been taken down again.
            try? await Task.sleep(for: .milliseconds(50))
            kill(getpid(), SIGINT)
            for _ in 0..<300 {
                if Task.isCancelled { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
        #expect(cancelled)
    }

    @Test("With interrupt handling off, the work runs to completion and its answer comes back")
    func withoutHandlingTheWorkFinishes() async {
        let answer = await Interruption.run(handlingInterrupts: false) { "finished" }
        #expect(answer == "finished")
    }

    @Test("A cancelled update reports what it had already done, and what it never started")
    func cancelledUpdateSaysWhatHappened() throws {
        let git = PlannedUpdateFactory.candidate("brew:git", installed: "2.43.0", available: "2.44.0")
        let plan = PlannedUpdateFactory.plan(
            for: git,
            steps: [PlannedUpdateFactory.step("/opt/homebrew/bin/brew", ["upgrade", "--formula", "--yes", "git"])]
        )
        let report = ExecutionReport(
            origin: .cli,
            dryRun: false,
            startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_790_000_030),
            cancelled: true,
            executed: [ExecutedUpdate(
                item: git.id,
                displayName: git.displayName,
                plan: plan,
                result: ExecutionResult(
                    planID: plan.id,
                    item: git.id,
                    outcome: .cancelled,
                    startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                    finishedAt: Date(timeIntervalSince1970: 1_790_000_020),
                    error: MacUpError(.cancelled, "MacUp stopped before running the rest of this update.")
                )
            )],
            skipped: [SkippedUpdate(
                item: try PackageID(parsing: "brew:mysql"),
                displayName: "mysql",
                currentVersion: "9.7.1",
                proposedVersion: "26.7.0_2",
                reason: "MacUp stopped before this item because the run was cancelled."
            )]
        )

        let rendered = ExecutionRenderer(
            report: report,
            style: TextStyle(enabled: false, homeDirectory: "/Users/example"),
            verbose: false
        ).render()
        #expect(rendered.contains("brew:git"))
        #expect(rendered.contains("cancelled part-way"))
        #expect(rendered.contains("brew:mysql"))
        #expect(rendered.contains("stopped before this item"))
        #expect(rendered.contains("The run was cancelled."))
        #expect(rendered.contains("nothing else was started"))
    }
}
