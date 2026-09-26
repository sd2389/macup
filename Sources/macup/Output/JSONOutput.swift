import Foundation
import MacUpCore

/// Encodes machine-readable output: sorted keys, ISO 8601 dates, one
/// trailing newline. Every top-level document carries `schemaVersion` and `kind`.
enum JSONOutput {
    static func encode<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return escapingTerminalControls(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    /// JSONEncoder escapes only C0 controls. DEL, C1 controls, bidirectional
    /// overrides, and line/paragraph separators can still act on a terminal
    /// the output is printed to, so they become `\uXXXX` escapes. JSONEncoder
    /// emits such scalars only inside string literals, so this is lossless
    /// for JSON readers; C0 (including the newlines of pretty-printing) is left alone.
    static func escapingTerminalControls(_ json: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in json.unicodeScalars {
            if scalar.value >= 0x20 && (TerminalText.isUnsafe(scalar) || scalar.value == 0x2028 || scalar.value == 0x2029) {
                result.append(contentsOf: String(format: "\\u%04x", scalar.value).unicodeScalars)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }
}
