import Foundation

enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

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
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    nonisolated subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    nonisolated var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    nonisolated var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    nonisolated var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

extension JSONValue {
    nonisolated static func stringArray(_ values: [String]) -> JSONValue {
        .array(values.map { .string($0) })
    }

    nonisolated static func nullableString(description: String? = nil) -> JSONValue {
        var properties: [String: JSONValue] = ["type": .array([.string("string"), .string("null")])]
        if let description {
            properties["description"] = .string(description)
        }
        return .object(properties)
    }

    nonisolated static func nullableInteger(description: String? = nil) -> JSONValue {
        var properties: [String: JSONValue] = ["type": .array([.string("integer"), .string("null")])]
        if let description {
            properties["description"] = .string(description)
        }
        return .object(properties)
    }

    nonisolated static func nullableBoolean(description: String? = nil) -> JSONValue {
        var properties: [String: JSONValue] = ["type": .array([.string("boolean"), .string("null")])]
        if let description {
            properties["description"] = .string(description)
        }
        return .object(properties)
    }
}
