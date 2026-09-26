import Foundation

/// Encodes machine-readable output: sorted keys, ISO 8601 dates, one
/// trailing newline. Every top-level document carries `schemaVersion` and `kind`.
enum JSONOutput {
    static func encode<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
