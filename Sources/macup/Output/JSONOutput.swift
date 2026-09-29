import Foundation
import MacUpCore

/// Encodes machine-readable output: sorted keys, ISO 8601 dates, one
/// trailing newline. Every top-level document carries `schemaVersion` and `kind`.
enum JSONOutput {
    static func encode<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        // Escaped in MacUpCore, so an exported diagnostics file, which the
        // app writes too, is made safe to print by the same code.
        return TerminalText.escapingUnsafeScalars(inJSON: String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}
