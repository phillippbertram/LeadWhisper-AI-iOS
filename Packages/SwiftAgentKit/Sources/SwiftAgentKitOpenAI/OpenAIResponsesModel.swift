import Foundation
import SwiftAgentKit

public actor OpenAIResponsesModel: AgentModel {
    public nonisolated let descriptor: AgentModelDescriptor

    private let endpoint: URL
    private let modelID: String
    private let storesResponses: Bool
    private let configuredUnavailableMessage: String?
    private let apiKeyProvider: @Sendable () async throws -> String?
    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        modelID: String,
        displayName: String,
        contextWindow: Int,
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        storesResponses: Bool = true,
        urlSession: URLSession = .shared,
        unavailableMessage: String? = nil,
        apiKeyProvider: @escaping @Sendable () async throws -> String?
    ) {
        self.modelID = modelID
        self.endpoint = endpoint
        self.storesResponses = storesResponses
        self.urlSession = urlSession
        configuredUnavailableMessage = unavailableMessage
        self.apiKeyProvider = apiKeyProvider
        descriptor = AgentModelDescriptor(
            id: "openai.responses.\(modelID)",
            displayName: displayName,
            contextWindow: contextWindow,
            capabilities: [.structuredOutput, .toolCalling]
        )
    }

    public func availability() async -> AgentModelAvailability {
        do {
            let available = try await apiKeyProvider() != nil
            return AgentModelAvailability(
                isAvailable: available,
                message: available ? "OpenAI API key saved." : "OpenAI API key missing.",
                unavailableMessage: configuredUnavailableMessage ?? "Provide an OpenAI API key before invoking this model."
            )
        } catch {
            return AgentModelAvailability(
                isAvailable: false,
                message: "OpenAI credential unavailable.",
                unavailableMessage: configuredUnavailableMessage ?? "The OpenAI API key could not be read."
            )
        }
    }

    public func prewarm(tools: [AnyAgentTool]) async {
        // Network providers do not need eager session warmup.
    }

    public func reset() async {
        // Each Responses API invocation carries its own transient tool loop.
    }

    public func invoke(
        _ request: AgentModelRequest,
        executor: AgentToolExecutor
    ) async throws -> AgentModelResponse {
        guard let apiKey = try await apiKeyProvider() else {
            throw OpenAIResponsesError.missingAPIKey
        }

        let toolsByName = Dictionary(uniqueKeysWithValues: request.tools.map { ($0.name, $0) })
        var input: [JSONValue] = [
            .object([
                "role": .string("user"),
                "content": .string(Self.promptWithMemory(request))
            ])
        ]

        while true {
            let response = try await createResponse(
                apiKey: apiKey,
                request: request,
                input: input
            )
            let calls = try functionCalls(from: response.output)
            if calls.isEmpty {
                return AgentModelResponse(output: try structuredOutput(from: response))
            }

            input.append(contentsOf: response.output)
            for call in calls {
                guard toolsByName[call.name] != nil else {
                    throw AgentRuntimeError.unknownTool(call.name)
                }
                let result = try await executor.execute(
                    name: call.name,
                    arguments: call.arguments,
                    callID: call.callID
                )
                input.append(.object([
                    "type": .string("function_call_output"),
                    "call_id": .string(call.callID),
                    "output": .string(result.modelContent)
                ]))
            }
        }
    }

    public func contextUsage(for request: AgentModelRequest) async throws -> AgentContextUsage {
        await estimatedContextUsage(for: request)
    }

    public func estimatedContextUsage(for request: AgentModelRequest) async -> AgentContextUsage {
        let instructionsTokens = Self.roughTokenCount(request.instructions)
        let inputTokens = Self.roughTokenCount(Self.promptWithMemory(request))
        let toolTokens = request.tools.reduce(0) { partial, tool in
            partial + Self.roughTokenCount(tool.name + tool.description + Self.jsonText(tool.argumentsSchema.jsonSchema))
        }
        let schemaTokens = Self.roughTokenCount(Self.jsonText(request.outputSchema.jsonSchema))
        let memoryTokens = Self.roughTokenCount(request.memoryPrompt ?? "")
        let used = min(descriptor.contextWindow, instructionsTokens + inputTokens + toolTokens + schemaTokens)
        return AgentContextUsage(
            usedTokens: used,
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
        if case OpenAIResponsesError.missingAPIKey = error {
            return .authentication
        }
        if case OpenAIResponsesError.api(let statusCode, let message) = error {
            let key = message.lowercased()
            if statusCode == 400 && (key.contains("context") || key.contains("token")) {
                return .contextWindow
            }
            switch statusCode {
            case 401, 403:
                return .authentication
            case 408, 500...599:
                return .transient
            case 429:
                return .rateLimited
            case 400...499:
                return .invalidRequest
            default:
                return .unknown
            }
        }
        let message = error.localizedDescription.lowercased()
        if message.contains("context window") || message.contains("too many tokens") {
            return .contextWindow
        }
        return .unknown
    }

    private func createResponse(
        apiKey: String,
        request: AgentModelRequest,
        input: [JSONValue]
    ) async throws -> OpenAIResponse {
        var body: [String: JSONValue] = [
            "model": .string(modelID),
            "instructions": .string(request.instructions),
            "input": .array(input),
            "max_output_tokens": .number(Double(request.responseTokenLimit)),
            "parallel_tool_calls": .bool(false),
            "store": .bool(storesResponses),
            "tool_choice": .string("auto"),
            "text": .object([
                "format": .object([
                    "type": .string("json_schema"),
                    "name": .string(request.outputName),
                    "strict": .bool(true),
                    "schema": request.outputSchema.jsonSchema
                ])
            ])
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map(Self.openAITool))
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try encoder.encode(JSONValue.object(body))

        let (data, response) = try await urlSession.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIResponsesError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAIResponsesError.api(
                statusCode: httpResponse.statusCode,
                message: apiErrorMessage(from: data)
            )
        }

        let json = try decoder.decode(JSONValue.self, from: data)
        return OpenAIResponse(json: json)
    }

    private func apiErrorMessage(from data: Data) -> String {
        guard let json = try? decoder.decode(JSONValue.self, from: data) else {
            return "OpenAI request failed."
        }
        return json["error"]?["message"]?.stringValue ?? "OpenAI request failed."
    }

    private func functionCalls(from output: [JSONValue]) throws -> [OpenAIFunctionCall] {
        try output.compactMap { item in
            guard item["type"]?.stringValue == "function_call" else { return nil }
            guard let name = item["name"]?.stringValue,
                  let callID = item["call_id"]?.stringValue ?? item["id"]?.stringValue else {
                throw OpenAIResponsesError.invalidToolCall
            }
            let rawArguments = item["arguments"]?.stringValue ?? "{}"
            guard let data = rawArguments.data(using: .utf8) else {
                throw OpenAIResponsesError.invalidToolCall
            }
            return OpenAIFunctionCall(
                callID: callID,
                name: name,
                arguments: try decoder.decode(JSONValue.self, from: data)
            )
        }
    }

    private func structuredOutput(from response: OpenAIResponse) throws -> JSONValue {
        guard let text = response.outputText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
              let data = text.data(using: .utf8) else {
            throw OpenAIResponsesError.noStructuredOutput
        }
        do {
            return try decoder.decode(JSONValue.self, from: data)
        } catch {
            guard let extracted = Self.extractJSONObject(from: text)?.data(using: .utf8) else {
                throw OpenAIResponsesError.decoding(error.localizedDescription)
            }
            do {
                return try decoder.decode(JSONValue.self, from: extracted)
            } catch {
                throw OpenAIResponsesError.decoding(error.localizedDescription)
            }
        }
    }

    private static func openAITool(_ tool: AnyAgentTool) -> JSONValue {
        .object([
            "type": .string("function"),
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": tool.argumentsSchema.jsonSchema,
            "strict": .bool(true)
        ])
    }

    private static func promptWithMemory(_ request: AgentModelRequest) -> String {
        [request.memoryPrompt, request.prompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            .joined(separator: "\n")
    }

    private static func roughTokenCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, Int((Double(text.count) / 4).rounded(.up)))
    }

    private static func jsonText(_ value: JSONValue) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return String(text[start...end])
    }
}

private struct OpenAIResponse {
    var json: JSONValue

    var output: [JSONValue] {
        json["output"]?.arrayValue ?? []
    }

    var outputText: String {
        if let text = json["output_text"]?.stringValue {
            return text
        }
        return output.flatMap { item -> [String] in
            if let text = item["text"]?.stringValue {
                return [text]
            }
            return item["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue } ?? []
        }
        .joined(separator: "\n")
    }
}

private struct OpenAIFunctionCall {
    var callID: String
    var name: String
    var arguments: JSONValue
}

public enum OpenAIResponsesError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidResponse
    case invalidToolCall
    case noStructuredOutput
    case decoding(String)
    case api(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "OpenAI API key missing."
        case .invalidResponse:
            "OpenAI returned an invalid response."
        case .invalidToolCall:
            "OpenAI returned an invalid tool call."
        case .noStructuredOutput:
            "OpenAI did not return structured output."
        case .decoding(let reason):
            "OpenAI returned structured output that could not be decoded. \(reason)"
        case .api(let statusCode, let message):
            "OpenAI request failed with status \(statusCode). \(message)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
