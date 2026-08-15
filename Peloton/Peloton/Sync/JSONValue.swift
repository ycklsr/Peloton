import Foundation

/// Any JSON value, which Swift knows how to carry without understanding it.
///
/// The domain content of a fact ("45-minute maths session") is written and
/// read by the HTML. Swift has no reason to know what a session is: it merely
/// ferries the bag around. This type is that bag.
///
/// Practical consequence: **adding a new piece of domain data requires no
/// change to the Swift.**
nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Decoding

    init(from decoder: Decoder) throws {
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
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Valeur JSON non reconnue")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:              try container.encodeNil()
        case .bool(let value):   try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value):  try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Bridges to the `Any` world (the WebKit bridge hands us `Any`)

    /// Converts what comes out of a `WKScriptMessage` (always raw Foundation
    /// types) into a typed value. `nil` if the object is not JSON.
    init?(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // NSNumber does not tell `true` from `1`: we query the underlying
            // Objective-C type, the only reliable way to separate them.
            self = String(cString: number.objCType) == "c"
                ? .bool(number.boolValue)
                : .number(number.doubleValue)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            // Fail outright rather than silently lose an element.
            var array: [JSONValue] = []
            for element in value {
                guard let converted = JSONValue(any: element) else { return nil }
                array.append(converted)
            }
            self = .array(array)
        case let value as [String: Any]:
            var object: [String: JSONValue] = [:]
            for (key, element) in value {
                guard let converted = JSONValue(any: element) else { return nil }
                object[key] = converted
            }
            self = .object(object)
        default:
            return nil
        }
    }

    /// Read access, for the rare places where Swift needs a field
    /// (importing the old file, for instance).
    subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
