import Foundation

struct AgentConversationMessage: Identifiable {
    let id = UUID()
    var content: AgentMessageContent

    static func user(_ text: String) -> AgentConversationMessage {
        AgentConversationMessage(content: .user(text))
    }

    static func assistant(_ title: String, detail: String?, systemImage: String) -> AgentConversationMessage {
        AgentConversationMessage(content: .assistant(title: title, detail: detail, systemImage: systemImage))
    }

    static func followUpOverview(title: String, items: [AgentFollowUpOverviewItem]) -> AgentConversationMessage {
        AgentConversationMessage(content: .followUpOverview(title: title, items: items))
    }

    static func result(_ runResult: AgentRunResult, transcript: String) -> AgentConversationMessage {
        AgentConversationMessage(content: .result(runResult, transcript: transcript))
    }

    static func receipt(_ changedRecords: [ChangedCRMRecord]) -> AgentConversationMessage {
        AgentConversationMessage(content: .receipt(changedRecords))
    }

    var resultID: UUID? {
        if case .result(let runResult, _) = content {
            return runResult.id
        }
        return nil
    }
}

enum AgentMessageContent {
    case assistant(title: String, detail: String?, systemImage: String)
    case followUpOverview(title: String, items: [AgentFollowUpOverviewItem])
    case user(String)
    case result(AgentRunResult, transcript: String)
    case receipt([ChangedCRMRecord])
}
