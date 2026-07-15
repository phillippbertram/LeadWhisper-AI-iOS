import Foundation

public enum AgentMemoryEntry: Sendable, Hashable {
    case user(String)
    case assistant(String)
    case system(String)
}

public protocol AgentMemory: AnyObject, Sendable {
    func context() async -> String?
    func record(_ entry: AgentMemoryEntry) async
    func reset() async
}

public actor SlidingWindowAgentMemory: AgentMemory {
    private let maximumEntries: Int
    private let maximumCharactersPerEntry: Int
    private var entries: [AgentMemoryEntry] = []

    public init(maximumEntries: Int = 8, maximumCharactersPerEntry: Int = 500) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumCharactersPerEntry = max(20, maximumCharactersPerEntry)
    }

    public func context() -> String? {
        guard !entries.isEmpty else { return nil }
        return (["Context memory from earlier turns:"] + entries.map(render)).joined(separator: "\n")
    }

    public func record(_ entry: AgentMemoryEntry) {
        entries.append(compact(entry))
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
    }

    public func reset() {
        entries.removeAll(keepingCapacity: true)
    }

    private func compact(_ entry: AgentMemoryEntry) -> AgentMemoryEntry {
        switch entry {
        case .user(let value):
            .user(compact(value))
        case .assistant(let value):
            .assistant(compact(value))
        case .system(let value):
            .system(compact(value))
        }
    }

    private func compact(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumCharactersPerEntry else { return trimmed }
        return "\(trimmed.prefix(maximumCharactersPerEntry - 3))..."
    }

    private func render(_ entry: AgentMemoryEntry) -> String {
        switch entry {
        case .user(let value):
            "- User: \(value)"
        case .assistant(let value):
            "- Assistant: \(value)"
        case .system(let value):
            "- Note: \(value)"
        }
    }
}

public struct AgentToolSelection: Sendable, Hashable {
    public var toolNames: [String]
    public var reason: String

    public init(toolNames: [String], reason: String) {
        self.toolNames = toolNames
        self.reason = reason
    }
}

public struct AnyAgentToolSelector: Sendable {
    private let selectTools: @Sendable (String, [AnyAgentTool]) async -> AgentToolSelection

    public init(_ select: @escaping @Sendable (String, [AnyAgentTool]) async -> AgentToolSelection) {
        selectTools = select
    }

    public func select(for input: String, from tools: [AnyAgentTool]) async -> AgentToolSelection {
        await selectTools(input, tools)
    }

    public static var all: AnyAgentToolSelector {
        AnyAgentToolSelector { _, tools in
            AgentToolSelection(toolNames: tools.map(\.name), reason: "All configured tools are available.")
        }
    }
}
