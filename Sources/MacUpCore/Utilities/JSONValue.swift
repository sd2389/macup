import Foundation

/// A parsed JSON document, used to read provider output defensively.
///
/// Provider output is untrusted input: parsers walk this tree, check every
/// type they rely on, ignore fields they do not know, and report entries they
/// cannot read instead of guessing.
public enum JSONValue: Sendable, Hashable, Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    /// Parses `data`, returning `nil` when it is not valid JSON.
    public static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }


    /// A string, or every string in an array of strings (Homebrew reports
    /// installed versions both ways across versions).
    public var stringList: [String]? {
        switch self {
        case .string(let string):
            return [string]
        case .array(let array):
            let strings = array.compactMap(\.stringValue)
            return strings.count == array.count ? strings : nil
        default:
            return nil
        }
    }
}
