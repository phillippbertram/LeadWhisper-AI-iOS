import Foundation
import FoundationModels
import SwiftAgentKit

public actor FoundationModelsModel: AgentModel {
    public nonisolated let descriptor: AgentModelDescriptor

    private let model: SystemLanguageModel
    private let configuredUnavailableMessage: String?
    private let router = FoundationToolRouter()
    private var session: LanguageModelSession?
    private var activeSignature: SessionSignature?
    private var fallbackSessionTokens = 0

    public init(
        model: SystemLanguageModel = .default,
        displayName: String = "Apple Foundation Models",
        unavailableMessage: String? = nil
    ) {
        self.model = model
        configuredUnavailableMessage = unavailableMessage
        descriptor = AgentModelDescriptor(
            id: "apple.foundation-models.default",
            displayName: displayName,
            contextWindow: model.contextSize,
            capabilities: [.structuredOutput, .toolCalling, .tokenCounting, .statefulSession]
        )
    }

    public func availability() async -> AgentModelAvailability {
        let message = Self.availabilityMessage(for: model.availability)
        return AgentModelAvailability(
            isAvailable: model.isAvailable,
            message: message,
            unavailableMessage: configuredUnavailableMessage ?? "Apple Foundation Models is unavailable. \(message)"
        )
    }

    public func prewarm(tools: [AnyAgentTool]) async {
        guard model.isAvailable else { return }
        LanguageModelSession(model: model).prewarm()
    }

    public func reset() async {
        session = nil
        activeSignature = nil
        fallbackSessionTokens = 0
        await router.clear()
    }

    public func invoke(
        _ request: AgentModelRequest,
        executor: AgentToolExecutor
    ) async throws -> AgentModelResponse {
        await router.use(executor)
        let generationSchema = try FoundationSchemaConverter.generationSchema(from: request.outputSchema)
        let tools = try request.tools.map { try DynamicFoundationTool(tool: $0, router: router) }
        let signature = SessionSignature(request: request)
        let activeSession: LanguageModelSession

        if request.sessionMode == .conversation,
           let session,
           activeSignature == signature {
            activeSession = session
        } else {
            activeSession = LanguageModelSession(
                model: model,
                tools: tools,
                instructions: request.instructions
            )
            if request.sessionMode == .conversation {
                session = activeSession
                activeSignature = signature
                fallbackSessionTokens = Self.roughTokenCount(request.instructions) + tools.count * 90
            }
        }

        let response = try await activeSession.respond(
            to: Self.promptWithMemory(request),
            schema: generationSchema,
            includeSchemaInPrompt: false,
            options: GenerationOptions(
                sampling: .greedy,
                maximumResponseTokens: request.responseTokenLimit
            )
        )

        if request.sessionMode == .conversation {
            do {
                fallbackSessionTokens = try await model.tokenCount(for: activeSession.transcript)
            } catch {
                fallbackSessionTokens += Self.roughTokenCount(Self.promptWithMemory(request))
            }
        }

        let data = Data(response.content.jsonString.utf8)
        return AgentModelResponse(output: try JSONDecoder().decode(JSONValue.self, from: data))
    }

    public func contextUsage(for request: AgentModelRequest) async throws -> AgentContextUsage {
        let promptTokens = try await model.tokenCount(for: Prompt(Self.promptWithMemory(request)))
        let memoryTokens: Int
        if let memoryPrompt = request.memoryPrompt {
            memoryTokens = try await model.tokenCount(for: Prompt(memoryPrompt))
        } else {
            memoryTokens = 0
        }
        let generationSchema = try FoundationSchemaConverter.generationSchema(from: request.outputSchema)
        let schemaTokens = try await model.tokenCount(for: generationSchema)
        let signature = SessionSignature(request: request)
        let baseTokens: Int

        if let session, activeSignature == signature {
            baseTokens = try await model.tokenCount(for: session.transcript)
        } else {
            let tools = try request.tools.map { try DynamicFoundationTool(tool: $0, router: router) }
            async let instructionTokens = model.tokenCount(for: Instructions(request.instructions))
            async let toolTokens = model.tokenCount(for: tools as [any Tool])
            baseTokens = try await instructionTokens + toolTokens
        }

        return AgentContextUsage(
            usedTokens: min(descriptor.contextWindow, baseTokens + promptTokens + schemaTokens),
            maximumTokens: descriptor.contextWindow,
            inputTokens: promptTokens,
            memoryTokens: memoryTokens,
            responseReserveTokens: request.responseTokenLimit,
            toolNames: request.tools.map(\.name),
            isEstimated: false
        )
    }

    public func estimatedContextUsage(for request: AgentModelRequest) async -> AgentContextUsage {
        let instructions = Self.roughTokenCount(request.instructions) + request.tools.count * 90
        let sessionTokens = activeSignature == SessionSignature(request: request) && fallbackSessionTokens > 0
            ? fallbackSessionTokens
            : instructions
        let inputTokens = Self.roughTokenCount(Self.promptWithMemory(request))
        let schemaTokens = Self.roughTokenCount(Self.schemaText(request.outputSchema))
        let memoryTokens = Self.roughTokenCount(request.memoryPrompt ?? "")
        return AgentContextUsage(
            usedTokens: min(descriptor.contextWindow, sessionTokens + inputTokens + schemaTokens),
            maximumTokens: descriptor.contextWindow,
            inputTokens: inputTokens,
            memoryTokens: memoryTokens,
            responseReserveTokens: request.responseTokenLimit,
            toolNames: request.tools.map(\.name),
            isEstimated: true
        )
    }

    public func classify(_ error: any Error) async -> AgentModelErrorClassification {
        if error is CancellationError {
            return .cancelled
        }
        if let generationError = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = generationError {
            return .contextWindow
        }
        let message = error.localizedDescription.lowercased()
        if message.contains("context window") || message.contains("model context") {
            return .contextWindow
        }
        return .unknown
    }

    private static func promptWithMemory(_ request: AgentModelRequest) -> String {
        [request.memoryPrompt, request.prompt]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: "\n")
    }

    private static func availabilityMessage(for availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            "Apple Foundation Models available"
        case .unavailable(.appleIntelligenceNotEnabled):
            "Apple Intelligence is not enabled."
        case .unavailable(.deviceNotEligible):
            "This device is not eligible for Apple Intelligence."
        case .unavailable(.modelNotReady):
            "The on-device model is not ready yet."
        @unknown default:
            "Foundation Models availability is unknown."
        }
    }

    private static func roughTokenCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, Int((Double(text.count) / 4).rounded(.up)))
    }

    private static func schemaText(_ schema: AgentSchema) -> String {
        let data = (try? JSONEncoder().encode(schema.jsonSchema)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private struct SessionSignature: Equatable {
    var instructions: String
    var outputSchema: AgentSchema
    var toolNames: [String]

    init(request: AgentModelRequest) {
        instructions = request.instructions
        outputSchema = request.outputSchema
        toolNames = request.tools.map(\.name)
    }
}

private actor FoundationToolRouter {
    private var executor: AgentToolExecutor?

    func use(_ executor: AgentToolExecutor) {
        self.executor = executor
    }

    func clear() {
        executor = nil
    }

    func execute(name: String, arguments: JSONValue) async throws -> AgentToolResult {
        guard let executor else {
            throw FoundationModelsAdapterError.missingExecutor
        }
        return try await executor.execute(name: name, arguments: arguments)
    }
}

private struct DynamicFoundationTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let router: FoundationToolRouter

    init(tool: AnyAgentTool, router: FoundationToolRouter) throws {
        name = tool.name
        description = tool.description
        parameters = try FoundationSchemaConverter.generationSchema(from: tool.argumentsSchema)
        self.router = router
    }

    @concurrent
    func call(arguments: GeneratedContent) async throws -> String {
        let data = Data(arguments.jsonString.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return try await router.execute(name: name, arguments: value).modelContent
    }
}

private enum FoundationSchemaConverter {
    static func generationSchema(from schema: AgentSchema) throws -> GenerationSchema {
        try GenerationSchema(root: dynamicSchema(from: schema), dependencies: [])
    }

    private static func dynamicSchema(from schema: AgentSchema) -> DynamicGenerationSchema {
        switch schema {
        case .object(let object):
            let properties = object.properties.map { property in
                let (propertySchema, nullable) = unwrapped(property.schema)
                return DynamicGenerationSchema.Property(
                    name: property.name,
                    description: property.description,
                    schema: dynamicSchema(from: propertySchema),
                    isOptional: property.isOptional || nullable
                )
            }
            return DynamicGenerationSchema(
                name: object.name,
                description: object.description,
                properties: properties
            )

        case .array(let items, let minimumCount, let maximumCount):
            return DynamicGenerationSchema(
                arrayOf: dynamicSchema(from: items),
                minimumElements: minimumCount,
                maximumElements: maximumCount
            )

        case .string(let description, let allowedValues):
            if let allowedValues {
                return DynamicGenerationSchema(
                    name: "StringChoice_\(stableIdentifier(for: allowedValues))",
                    description: description,
                    anyOf: allowedValues
                )
            }
            return DynamicGenerationSchema(type: String.self)

        case .integer:
            return DynamicGenerationSchema(type: Int.self)

        case .number:
            return DynamicGenerationSchema(type: Double.self)

        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)

        case .nullable(let wrapped):
            return dynamicSchema(from: wrapped)
        }
    }

    private static func unwrapped(_ schema: AgentSchema) -> (AgentSchema, Bool) {
        guard case .nullable(let wrapped) = schema else { return (schema, false) }
        return (wrapped, true)
    }

    private static func stableIdentifier(for values: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in values.joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private enum FoundationModelsAdapterError: LocalizedError {
    case missingExecutor

    var errorDescription: String? {
        "Foundation Models attempted a tool call outside an active agent invocation."
    }
}
