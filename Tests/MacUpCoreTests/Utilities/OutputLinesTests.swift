import Foundation
import Testing

@testable import MacUpCore

@Suite("Streamed output as display lines")
struct OutputLinesTests {
    private func chunk(_ text: String, _ stream: CommandOutputStream = .standardOutput) -> CommandOutputChunk {
        CommandOutputChunk(stream: stream, data: Data(text.utf8))
    }

    @Test("A line split across chunks comes out whole, once it ends")
    func splitLines() {
        let lines = OutputLines()
        #expect(lines.append(chunk("==> Downloading my")).isEmpty)
        #expect(lines.append(chunk("sql\n==> Pouring")) == ["==> Downloading mysql"])
        #expect(lines.append(chunk(" mysql\n")) == ["==> Pouring mysql"])
        #expect(lines.recent == ["==> Downloading mysql", "==> Pouring mysql"])
    }

    @Test("stdout and stderr are assembled separately, so they cannot splice into one line")
    func streamsStaySeparate() {
        let lines = OutputLines()
        lines.append(chunk("Warn", .standardError))
        lines.append(chunk("Building\n"))
        lines.append(chunk("ing: slow\n", .standardError))
        #expect(lines.recent == ["Building", "Warning: slow"])
    }

    @Test("A progress bar redrawn with carriage returns reads as its latest state, and only recent lines are kept")
    func carriageReturnsAndLimit() {
        let lines = OutputLines(limit: 2)
        lines.append(chunk("10%\r50%\r100%\ndone\n"))
        #expect(lines.recent == ["100%", "done"])
    }

    @Test("Secrets are redacted and terminal escapes neutralised before anyone sees a line")
    func untrustedOutputIsMadeSafe() {
        let lines = OutputLines()
        let shown = lines.append(chunk("token ghp_abcdefghijklmnopqrstuvwxyz0123 \u{1B}]0;evil\u{07}\n"))
        #expect(shown.count == 1)
        #expect(!shown[0].contains("ghp_abcdefghijklmnopqrstuvwxyz0123"))
        #expect(!shown[0].contains("\u{1B}"))
    }

    @Test("Resetting forgets the previous command's lines")
    func reset() {
        let lines = OutputLines()
        lines.append(chunk("old\nhalf"))
        lines.reset()
        lines.append(chunk("new\n"))
        #expect(lines.recent == ["new"])
    }
}
