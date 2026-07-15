# SwiftAgentKit

SwiftAgentKit is a small, provider-neutral agent runtime written in Swift. It is intentionally scoped as a showcase SDK: an app supplies a model, instructions, structured output schema, tools, memory, tool selection, hooks, and runtime policy from the outside.

The package borrows the useful V1 concepts from frameworks such as Strands Agents and LangChain without trying to reproduce their complete ecosystems. Multi-agent orchestration, MCP, plugins, persistent sessions, streaming, and agents-as-tools are not part of this version.

## Products

| Product | Responsibility |
| --- | --- |
| `SwiftAgentKit` | Provider-neutral runtime, schemas, tools, memory, policies, hooks, and events |
| `SwiftAgentKitOpenAI` | OpenAI Responses API model adapter |
| `SwiftAgentKitFoundationModels` | Apple Foundation Models adapter using dynamic generation schemas and dynamic tools |

The core target does not import either provider SDK and contains no provider enum. Provider selection belongs to the composing application.

## Runtime composition

```swift
import SwiftAgentKit
import SwiftAgentKitOpenAI

struct Answer: Codable, Sendable {
    var message: String

    static let outputSchema = AgentOutputSchema<Answer>(
        name: "answer",
        schema: .object(
            AgentSchema.Object(
                name: "Answer",
                properties: [
                    .init("message", schema: .string())
                ]
            )
        )
    )
}

let model = OpenAIResponsesModel(
    modelID: "your-model-id",
    displayName: "OpenAI",
    contextWindow: 128_000,
    apiKeyProvider: { keychain.readAPIKey() }
)

let agent = Agent<Answer>(
    model: model,
    instructions: "Answer briefly and use configured tools when needed.",
    outputSchema: Answer.outputSchema,
    tools: toolCatalog,
    memory: SlidingWindowAgentMemory(),
    toolSelector: .all,
    hooks: [timelineHook],
    policy: AgentPolicy(maximumToolCalls: 8, responseTokenLimit: 1_000)
)

let run = try await agent.run("What should I do next?")
print(run.output.message)
```

An app can pass an instruction closure instead of a fixed string when the prompt should reflect the tools selected for a turn.

## Schemas and tools

`AgentSchema` is the single runtime schema representation for both structured output and tool arguments. The OpenAI adapter converts it to strict JSON Schema. The Apple adapter converts the same value to `DynamicGenerationSchema`, receives `GeneratedContent`, and decodes its `jsonString` through the shared `Codable` type.

A tool defines its arguments once:

```swift
struct SearchArguments: Codable, Sendable {
    var query: String
}

struct SearchTool: AgentTool {
    let name = "search"
    let description = "Search the app's read-only local index."
    let argumentsSchema: AgentSchema = .object(
        AgentSchema.Object(
            name: "SearchArguments",
            properties: [.init("query", schema: .string())]
        )
    )

    func call(
        arguments: SearchArguments,
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        AgentToolResult(modelContent: await index.search(arguments.query))
    }
}

let erasedTool = AnyAgentTool(SearchTool())
```

The shared executor decodes arguments, applies the tool-call and repeat limits, emits lifecycle events, and invokes the same tool implementation for either provider.

## Adding a provider

Implement `AgentModel` in a separate adapter target:

- publish an `AgentModelDescriptor` with context size and capabilities;
- report availability without binding the model to app UI state;
- translate `AgentModelRequest` into the provider request;
- run requested tools through the supplied `AgentToolExecutor`;
- return structured content as `JSONValue`;
- measure or estimate context usage;
- reset any stateful session;
- classify provider errors, especially context-window failures.

The application can then construct that model and inject it into `Agent<Output>` without changing the runtime.

## Ownership boundary

SwiftAgentKit can call tools and return typed output, but it does not persist app data. LeadWhisper therefore keeps CRM validation, diffs, destructive confirmation, selective application, Keychain management, and SwiftData mutations outside this package.

Hooks are observing-only in V1. `AgentPolicy` and `AnyAgentToolSelector` are the explicit behavior-changing extension points.

## Macro roadmap

A later optional `SwiftAgentKitMacros` target could reduce schema boilerplate without changing the runtime API:

- `@AgentTool` could generate the `Codable` argument type, `AgentSchema`, and type-erased registration.
- `@AgentOutput` could generate `AgentOutputSchema` for a structured result.

V1 intentionally has no SwiftSyntax dependency. The explicit schema API remains the stable underlying contract even if macros are added later.
