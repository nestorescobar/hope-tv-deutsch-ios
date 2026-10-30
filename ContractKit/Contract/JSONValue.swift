import Foundation

/// A tolerant JSON value.
///
/// Block props and block resources are per-block shapes, so the decoder keeps them as
/// data and each renderer reads only the fields it knows. An unknown field is carried,
/// never a decode failure — that is contract rule 3 at the decoder level.
enum JSONValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null
}

extension JSONValue: Decodable {
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
            self = .null
        }
    }
}

extension JSONValue {
    /// Missing reads as `.null`, so a chain of lookups never needs an optional dance.
    subscript(key: String) -> JSONValue {
        guard case let .object(fields) = self else { return .null }
        return fields[key] ?? .null
    }

    subscript(index: Int) -> JSONValue {
        guard case let .array(items) = self, items.indices.contains(index) else { return .null }
        return items[index]
    }

    var string: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var double: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    /// Truncated toward zero. A number out of `Int` range (1e20, infinity) reads as nil: a plain
    /// `Int(Double)` traps, and author content can serve one.
    var int: Int? {
        guard case let .number(value) = self else { return nil }
        return Int(exactly: value.rounded(.towardZero))
    }

    var bool: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var array: [JSONValue] {
        guard case let .array(items) = self else { return [] }
        return items
    }

    var object: [String: JSONValue] {
        guard case let .object(fields) = self else { return [:] }
        return fields
    }

    var isNull: Bool { self == .null }

    /// Whether an object carries `key` at all, even as `null`. The subscript reads a missing
    /// key and a served `null` alike (`.null`); this tells them apart where a rule needs it.
    func hasKey(_ key: String) -> Bool {
        guard case let .object(fields) = self else { return false }
        return fields[key] != nil
    }

    /// A non-empty string, or nil. Empty text is "nothing to draw", not an empty label.
    var text: String? {
        guard let value = string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
