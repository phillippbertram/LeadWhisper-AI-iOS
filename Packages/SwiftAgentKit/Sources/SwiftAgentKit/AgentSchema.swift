import Foundation

public indirect enum AgentSchema: Sendable, Hashable {
    case object(Object)
    case array(items: AgentSchema, minimumCount: Int? = nil, maximumCount: Int? = nil)
    case string(description: String? = nil, allowedValues: [String]? = nil)
    case integer(description: String? = nil)
    case number(description: String? = nil)
    case boolean(description: String? = nil)
    case nullable(AgentSchema)

    public struct Object: Sendable, Hashable {
        public var name: String
        public var description: String?
        public var properties: [Property]

        public init(name: String, description: String? = nil, properties: [Property]) {
            self.name = name
            self.description = description
            self.properties = properties
        }
    }

    public struct Property: Sendable, Hashable {
        public var name: String
        public var description: String?
        public var schema: AgentSchema
        public var isOptional: Bool

        public init(
            _ name: String,
            description: String? = nil,
            schema: AgentSchema,
            isOptional: Bool = false
        ) {
            self.name = name
            self.description = description
            self.schema = schema
            self.isOptional = isOptional
        }
    }
}

public extension AgentSchema {
    var jsonSchema: JSONValue {
        switch self {
        case .object(let object):
            let properties = Dictionary(uniqueKeysWithValues: object.properties.map { property in
                var value = property.schema.jsonSchema
                if let description = property.description {
                    value = value.addingObjectValue(.string(description), forKey: "description")
                }
                return (property.name, value)
            })
            return .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object(properties),
                "required": .stringArray(object.properties.map(\.name))
            ])

        case .array(let items, let minimumCount, let maximumCount):
            var values: [String: JSONValue] = [
                "type": .string("array"),
                "items": items.jsonSchema
            ]
            if let minimumCount {
                values["minItems"] = .number(Double(minimumCount))
            }
            if let maximumCount {
                values["maxItems"] = .number(Double(maximumCount))
            }
            return .object(values)

        case .string(let description, let allowedValues):
            var values: [String: JSONValue] = ["type": .string("string")]
            if let description {
                values["description"] = .string(description)
            }
            if let allowedValues {
                values["enum"] = .stringArray(allowedValues)
            }
            return .object(values)

        case .integer(let description):
            return primitiveJSONSchema(type: "integer", description: description)

        case .number(let description):
            return primitiveJSONSchema(type: "number", description: description)

        case .boolean(let description):
            return primitiveJSONSchema(type: "boolean", description: description)

        case .nullable(let wrapped):
            guard case .object(var values) = wrapped.jsonSchema else {
                return .object(["anyOf": .array([wrapped.jsonSchema, .object(["type": .string("null")])])])
            }
            let existingType = values["type"]
            if case .string(let type) = existingType {
                values["type"] = .array([.string(type), .string("null")])
            } else {
                values["anyOf"] = .array([wrapped.jsonSchema, .object(["type": .string("null")])])
                values.removeValue(forKey: "type")
            }
            if case .array(let allowed) = values["enum"], !allowed.contains(.null) {
                values["enum"] = .array(allowed + [.null])
            }
            return .object(values)
        }
    }

    private func primitiveJSONSchema(type: String, description: String?) -> JSONValue {
        var values: [String: JSONValue] = ["type": .string(type)]
        if let description {
            values["description"] = .string(description)
        }
        return .object(values)
    }
}

private extension JSONValue {
    func addingObjectValue(_ value: JSONValue, forKey key: String) -> JSONValue {
        guard case .object(var values) = self else { return self }
        values[key] = value
        return .object(values)
    }
}

public struct AgentOutputSchema<Output: Decodable & Sendable>: Sendable {
    public var name: String
    public var schema: AgentSchema
    private let decodeValue: @Sendable (JSONValue) throws -> Output

    public init(
        _ type: Output.Type = Output.self,
        name: String,
        schema: AgentSchema,
        decode: @escaping @Sendable (JSONValue) throws -> Output = { value in
            try JSONValue.decode(Output.self, from: value)
        }
    ) {
        self.name = name
        self.schema = schema
        decodeValue = decode
    }

    public func decode(_ value: JSONValue) throws -> Output {
        try decodeValue(value)
    }
}
