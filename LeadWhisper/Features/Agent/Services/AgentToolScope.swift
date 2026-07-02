import Foundation
import FoundationModels

@Generable
enum AgentToolScope: String, CaseIterable, Codable, Sendable {
    case none
    case contacts
    case opportunities
    case followUps
    case pipeline
    case full

    var toolCount: Int {
        toolNames.count
    }

    var instructionHint: String {
        switch self {
        case .none:
            "No lookup tools are attached; draft from user facts or clarify."
        case .contacts:
            "Use contact lookup only to identify/read an existing contact."
        case .opportunities:
            "Use opportunity lookup only to identify an existing opportunity."
        case .followUps:
            "Use follow-up lookup only to identify an existing task."
        case .pipeline:
            "Use pipeline summary for counts, workload, and due-date overview."
        case .full:
            "Use lookup tools only for exact existing records, pipeline facts, or disambiguation."
        }
    }

    var toolNames: [String] {
        switch self {
        case .none:
            []
        case .contacts:
            ["findContacts", "getContactDetails"]
        case .opportunities:
            ["findOpportunities"]
        case .followUps:
            ["findFollowUps"]
        case .pipeline:
            ["getPipelineSummary"]
        case .full:
            ["findContacts", "findOpportunities", "findFollowUps", "getContactDetails", "getPipelineSummary"]
        }
    }
}

@Generable
struct AgentToolPlan: Codable, Sendable {
    @Guide(description: "Smallest safe lookup tool scope for the next agent turn. Use full if uncertain.")
    var toolScope: AgentToolScope

    @Guide(description: "Short reason for the chosen tool scope.")
    var reason: String
}

extension AgentToolPlan {
    static var fallback: AgentToolPlan {
        AgentToolPlan(toolScope: .full, reason: "Tool planning failed; all read-only lookup tools are available.")
    }

    static var openAIJSONSchema: JSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "toolScope": .object([
                    "type": .string("string"),
                    "enum": .stringArray(AgentToolScope.allCases.map(\.rawValue)),
                    "description": .string("Smallest safe lookup tool scope for the next agent turn. Use full if uncertain.")
                ]),
                "reason": .object([
                    "type": .string("string"),
                    "description": .string("Short reason for the chosen tool scope.")
                ])
            ]),
            "required": .stringArray(["toolScope", "reason"])
        ])
    }
}
