import Foundation

@MainActor
final class OpenAIResponsesAgentClient: AgentModelClient {
    let providerKind: AgentProviderKind = .openAI

    private enum Constants {
        static let model = "gpt-5.5"
        static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
        static let contextSize = 128_000
    }

    private let credentialStore: AgentCredentialStore
    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(credentialStore: AgentCredentialStore, urlSession: URLSession = .shared) {
        self.credentialStore = credentialStore
        self.urlSession = urlSession
    }

    var isAvailable: Bool {
        credentialStore.hasOpenAIAPIKey()
    }

    var availabilityMessage: String {
        isAvailable ? "OpenAI API key saved." : "OpenAI API key missing."
    }

    var unavailableErrorMessage: String {
        "Add an OpenAI API key in Settings to use the OpenAI provider. No local data was changed."
    }

    var contextSize: Int {
        Constants.contextSize
    }

    func prewarm(dataSource: AgentToolDataSource) {
        // Network providers do not need an eager session warmup.
    }

    func resetSession() {
        // The OpenAI v1 path sends compact memory each turn and only keeps
        // transient tool-roundtrip state inside `respond`.
    }

    func planTools(for request: AgentModelPlanRequest) async throws -> AgentToolPlan {
        guard let apiKey = try credentialStore.openAIAPIKey() else {
            throw OpenAIClientError.missingAPIKey
        }

        let response = try await createResponse(
            apiKey: apiKey,
            instructions: request.instructions,
            input: [
                .object([
                    "role": .string("user"),
                    "content": .string(request.prompt)
                ])
            ],
            tools: [],
            maxOutputTokens: request.responseTokenLimit,
            schemaName: "agent_tool_plan",
            schema: AgentToolPlan.openAIJSONSchema
        )

        return try decodeStructuredOutput(AgentToolPlan.self, from: response)
    }

    func respond(to request: AgentModelTurnRequest) async throws -> AgentModelTurnResponse {
        guard let apiKey = try credentialStore.openAIAPIKey() else {
            throw OpenAIClientError.missingAPIKey
        }

        let toolDefinitions = AgentToolDefinitions.definitions(
            for: request.toolScope,
            dataSource: request.dataSource,
            outputPolicy: request.toolOutputPolicy
        )
        let toolsByName = Dictionary(uniqueKeysWithValues: toolDefinitions.map { ($0.name, $0) })
        var input: [JSONValue] = [
            .object([
                "role": .string("user"),
                "content": .string(request.prompt)
            ])
        ]
        var timeline = baseTimeline(condensed: request.condensed)
        var toolCalls = 0

        while true {
            let response = try await createResponse(
                apiKey: apiKey,
                instructions: request.instructions,
                input: input,
                tools: toolDefinitions.map(\.openAITool),
                maxOutputTokens: request.responseTokenLimit,
                schemaName: "agent_turn",
                schema: AgentTurn.openAIJSONSchema
            )

            let calls = try functionCalls(from: response.output)
            if calls.isEmpty {
                let turn = try decodeStructuredOutput(AgentTurn.self, from: response)
                if let thought = turn.thought.nilIfBlank {
                    timeline.append(AgentTimelineItem(title: "Thought", detail: thought, systemImage: "brain"))
                }
                timeline.append(AgentTimelineItem(title: "Final answer", detail: "Structured AgentTurn received from OpenAI.", systemImage: "checkmark.seal"))
                return AgentModelTurnResponse(turn: turn, timeline: timeline)
            }

            input.append(contentsOf: response.output)

            for call in calls {
                toolCalls += 1
                guard toolCalls <= request.maxToolCalls else {
                    throw AgentToolBudgetExceeded(reason: "Local lookup budget exhausted.")
                }
                guard let tool = toolsByName[call.name] else {
                    throw OpenAIClientError.unknownTool(call.name)
                }

                timeline.append(AgentTimelineItem(title: "Action", detail: call.detail, systemImage: "wrench.and.screwdriver"))
                let output = try await tool.call(call.arguments)
                timeline.append(AgentTimelineItem(title: "Observation", detail: "\(call.name): \(Self.snippet(output))", systemImage: "tray.full"))
                input.append(.object([
                    "type": .string("function_call_output"),
                    "call_id": .string(call.callID),
                    "output": .string(output)
                ]))
            }
        }
    }

    func measuredContextWindowUsage(for request: AgentModelContextRequest) async throws -> AgentContextWindowUsage {
        // Avoid sending draft text to OpenAI just to count tokens while the user
        // is still typing. The UI uses the local estimate for cloud providers.
        estimatedContextWindowUsage(for: request)
    }

    func estimatedContextWindowUsage(for request: AgentModelContextRequest) -> AgentContextWindowUsage {
        let instructionsTokens = Self.roughTokenCount(request.instructions) + request.toolScope.toolCount * 120
        let inputTokens = Self.roughTokenCount(request.promptText)
        let schemaTokens = Self.roughTokenCount(Self.schemaDebugDescription)
        let memoryTokens = Self.roughTokenCount(request.memoryPrompt ?? "")
        let usedTokens = min(contextSize, instructionsTokens + inputTokens + schemaTokens)

        return AgentContextWindowUsage(
            usedTokens: usedTokens,
            maximumTokens: contextSize,
            inputTokens: inputTokens,
            memoryTokens: memoryTokens,
            responseReserveTokens: request.responseReserveTokens,
            toolScope: request.toolScope.rawValue,
            isEstimated: true
        )
    }

    func isContextWindowError(_ error: Error) -> Bool {
        if case OpenAIClientError.api(let statusCode, let message) = error {
            let key = message.searchKey
            return statusCode == 400 && (key.contains("context") || key.contains("token"))
        }

        let message = error.localizedDescription.searchKey
        return message.contains("context window") || message.contains("too many tokens")
    }

    private func createResponse(
        apiKey: String,
        instructions: String,
        input: [JSONValue],
        tools: [JSONValue],
        maxOutputTokens: Int,
        schemaName: String,
        schema: JSONValue
    ) async throws -> OpenAIResponse {
        var body: [String: JSONValue] = [
            "model": .string(Constants.model),
            "instructions": .string(instructions),
            "input": .array(input),
            "max_output_tokens": .number(Double(maxOutputTokens)),
            "parallel_tool_calls": .bool(false),
            "store": .bool(true),
            "tool_choice": .string("auto"),
            "text": .object([
                "format": .object([
                    "type": .string("json_schema"),
                    "name": .string(schemaName),
                    "strict": .bool(true),
                    "schema": schema
                ])
            ])
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools)
        }

        var urlRequest = URLRequest(url: Constants.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try encoder.encode(JSONValue.object(body))

        let (data, response) = try await urlSession.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAIClientError.api(statusCode: httpResponse.statusCode, message: apiErrorMessage(from: data))
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
                throw OpenAIClientError.invalidToolCall
            }

            let argumentText = item["arguments"]?.stringValue ?? "{}"
            let arguments = try decodeArguments(argumentText)
            return OpenAIFunctionCall(callID: callID, name: name, rawArguments: argumentText, arguments: arguments)
        }
    }

    private func decodeArguments(_ text: String) throws -> JSONValue {
        guard let data = text.data(using: .utf8) else {
            throw OpenAIClientError.invalidToolCall
        }
        return try decoder.decode(JSONValue.self, from: data)
    }

    private func decodeStructuredOutput<T: Decodable>(_ type: T.Type, from response: OpenAIResponse) throws -> T {
        guard let text = response.outputText.nilIfBlank else {
            throw OpenAIClientError.noStructuredOutput
        }
        let data = Data(text.utf8)
        do {
            return try decoder.decode(type, from: data)
        } catch {
            guard let extracted = Self.extractJSONObject(from: text)?.data(using: .utf8) else {
                throw OpenAIClientError.decoding(error.localizedDescription)
            }
            do {
                return try decoder.decode(type, from: extracted)
            } catch {
                throw OpenAIClientError.decoding(error.localizedDescription)
            }
        }
    }

    private func baseTimeline(condensed: Bool) -> [AgentTimelineItem] {
        guard condensed else { return [] }
        return [
            AgentTimelineItem(title: "Context condensed", detail: "The conversation was restarted to fit the selected model.", systemImage: "arrow.triangle.2.circlepath")
        ]
    }

    private static func snippet(_ text: String) -> String {
        guard text.count > 160 else { return text }
        return "\(text.prefix(157))..."
    }

    private static func roughTokenCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, Int((Double(text.count) / 4.0).rounded(.up)))
    }

    private static var schemaDebugDescription: String {
        let data = (try? JSONEncoder().encode(AgentTurn.openAIJSONSchema)) ?? Data()
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

        let chunks = output.flatMap { item -> [String] in
            if let text = item["text"]?.stringValue {
                return [text]
            }
            return item["content"]?.arrayValue?.compactMap { content in
                content["text"]?.stringValue
            } ?? []
        }
        return chunks.joined(separator: "\n")
    }
}

private struct OpenAIFunctionCall {
    var callID: String
    var name: String
    var rawArguments: String
    var arguments: JSONValue

    var detail: String {
        guard !rawArguments.isEmpty, rawArguments != "{}" else { return name }
        return "\(name) \(String(rawArguments.prefix(80)))"
    }
}

private enum OpenAIClientError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case invalidToolCall
    case unknownTool(String)
    case noStructuredOutput
    case decoding(String)
    case api(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "OpenAI API key missing."
        case .invalidResponse:
            "OpenAI returned an invalid response."
        case .invalidToolCall:
            "OpenAI returned an invalid tool call."
        case .unknownTool(let name):
            "OpenAI requested an unavailable local tool: \(name)."
        case .noStructuredOutput:
            "OpenAI did not return structured output."
        case .decoding(let reason):
            "OpenAI returned a structured turn that could not be decoded. \(reason)"
        case .api(let statusCode, let message):
            "OpenAI request failed with status \(statusCode). \(message)"
        }
    }
}
