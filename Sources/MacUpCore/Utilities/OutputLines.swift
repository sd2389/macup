import Foundation

/// Turns a command's streamed output into whole, display-safe lines.
///
/// Output arrives in chunks that can end part-way through a line, or part-way
/// through a UTF-8 character; the unfinished part is held until the rest
/// arrives. A carriage return ends a line too, so a progress bar redrawing
/// itself reads as its latest state. Every line is redacted and made
/// terminal-safe before anyone sees it, because provider output is untrusted
/// input (CLAUDE.md §19). Only the most recent `limit` lines are kept.
public final class OutputLines: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let redactor = Redactor()
    private var pending: [CommandOutputStream: Data] = [:]
    private var lines: [String] = []

    public init(limit: Int = 8) {
        self.limit = max(1, limit)
    }

    /// Adds a chunk and returns the lines it completed, oldest first.
    @discardableResult
    public func append(_ chunk: CommandOutputChunk) -> [String] {
        lock.withLock {
            var buffer = (pending[chunk.stream] ?? Data()) + chunk.data
            var completed: [String] = []
            while let end = buffer.firstIndex(where: { $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") }) {
                let line = buffer[buffer.startIndex..<end]
                buffer = Data(buffer[buffer.index(after: end)...])
                if let text = display(line) { completed.append(text) }
            }
            // A line with no end in sight is still kept bounded.
            if buffer.count > 4096 {
                if let text = display(buffer.prefix(4096)) { completed.append(text) }
                buffer = Data()
            }
            pending[chunk.stream] = buffer
            lines = Array((lines + completed).suffix(limit))
            return completed
        }
    }

    /// The most recent complete lines, oldest first.
    public var recent: [String] {
        lock.withLock { lines }
    }

    /// Forgets everything, for the next command.
    public func reset() {
        lock.withLock {
            pending = [:]
            lines = []
        }
    }

    private func display(_ data: Data) -> String? {
        let text = TerminalText.sanitize(redactor.redact(String(decoding: data, as: UTF8.self)))
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
