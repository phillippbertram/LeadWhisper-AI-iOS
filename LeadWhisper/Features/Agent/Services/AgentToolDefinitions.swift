import Foundation
import OSLog

struct AgentToolDefinition {
    var name: String
    var description: String
    var parameters: JSONValue
    var call: @Sendable (_ arguments: JSONValue) async throws -> String

    var openAITool: JSONValue {
        .object([
            "type": .string("function"),
            "name": .string(name),
            "description": .string(description),
            "parameters": parameters,
            "strict": .bool(true)
        ])
    }
}

enum AgentToolDefinitions {
    static func definitions(
        for scope: AgentToolScope,
        dataSource: AgentToolDataSource,
        outputPolicy: AgentToolOutputPolicy
    ) -> [AgentToolDefinition] {
        scope.toolNames.compactMap {
            definition(named: $0, dataSource: dataSource, outputPolicy: outputPolicy)
        }
    }

    static func definition(
        named name: String,
        dataSource: AgentToolDataSource,
        outputPolicy: AgentToolOutputPolicy
    ) -> AgentToolDefinition? {
        switch name {
        case "findContacts":
            AgentToolDefinition(
                name: "findContacts",
                description: "Search existing local CRM contacts by name, company, notes, or tags. This tool is read-only.",
                parameters: querySchema(description: "Short name, company, or keyword."),
                call: { arguments in
                    let query = arguments["query"]?.stringValue ?? ""
                    guard !query.searchKey.isEmpty else {
                        AppLog.tools.warning("findContacts rejected empty query")
                        return ToolText.emptyQuery
                    }
                    let matches = try await dataSource.contacts(query, outputPolicy.resultLimit)
                    AppLog.tools.debug("findContacts query=\(query, privacy: .private) returned=\(matches.count, privacy: .public)")
                    return ToolText.contacts(matches, policy: outputPolicy)
                }
            )

        case "findOpportunities":
            AgentToolDefinition(
                name: "findOpportunities",
                description: "Search existing local CRM opportunities by title, company, stage, budget, or tags. This tool is read-only.",
                parameters: querySchema(description: "Short title, company, stage, or keyword."),
                call: { arguments in
                    let query = arguments["query"]?.stringValue ?? ""
                    guard !query.searchKey.isEmpty else {
                        AppLog.tools.warning("findOpportunities rejected empty query")
                        return ToolText.emptyQuery
                    }
                    let matches = try await dataSource.opportunities(query, outputPolicy.resultLimit)
                    AppLog.tools.debug("findOpportunities query=\(query, privacy: .private) returned=\(matches.count, privacy: .public)")
                    return ToolText.opportunities(matches, policy: outputPolicy)
                }
            )

        case "findFollowUps":
            AgentToolDefinition(
                name: "findFollowUps",
                description: "Search existing local CRM follow-up tasks by title, due date text, notes, or state. This tool is read-only.",
                parameters: querySchema(description: "Short contact, title, date, or keyword."),
                call: { arguments in
                    let query = arguments["query"]?.stringValue ?? ""
                    guard !query.searchKey.isEmpty else {
                        AppLog.tools.warning("findFollowUps rejected empty query")
                        return ToolText.emptyQuery
                    }
                    let matches = try await dataSource.followUps(query, outputPolicy.resultLimit)
                    AppLog.tools.debug("findFollowUps query=\(query, privacy: .private) returned=\(matches.count, privacy: .public)")
                    return ToolText.followUps(matches, policy: outputPolicy)
                }
            )

        case "getContactDetails":
            AgentToolDefinition(
                name: "getContactDetails",
                description: "Read one contact's full local details: role, email, phone, notes, tags, opportunities, and open follow-ups. This tool is read-only.",
                parameters: querySchema(description: "Contact name or company to look up."),
                call: { arguments in
                    let query = arguments["query"]?.stringValue ?? ""
                    guard !query.searchKey.isEmpty else {
                        AppLog.tools.warning("getContactDetails rejected empty query")
                        return ToolText.emptyQuery
                    }
                    let snapshot = try await dataSource.snapshot()
                    AppLog.tools.debug("getContactDetails query=\(query, privacy: .private)")
                    return ToolText.contactDetails(snapshot, query: query, policy: outputPolicy)
                }
            )

        case "getPipelineSummary":
            AgentToolDefinition(
                name: "getPipelineSummary",
                description: "Summarize the local CRM: contact count, opportunities per stage, and open follow-ups with due dates. This tool is read-only.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "focus": .nullableString(description: "Optional focus: contacts, opportunities, or followUps.")
                    ]),
                    "required": .stringArray(["focus"]),
                    "additionalProperties": .bool(false)
                ]),
                call: { arguments in
                    let snapshot = try await dataSource.snapshot()
                    let focus = arguments["focus"]?.stringValue
                    AppLog.tools.debug("getPipelineSummary focus=\(focus ?? "-", privacy: .public) contacts=\(snapshot.contacts.count, privacy: .public) opportunities=\(snapshot.opportunities.count, privacy: .public) followUps=\(snapshot.followUps.count, privacy: .public)")
                    return ToolText.pipelineSummary(snapshot, focus: focus, policy: outputPolicy)
                }
            )

        default:
            nil
        }
    }

    private static func querySchema(description: String) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string(description)
                ])
            ]),
            "required": .stringArray(["query"]),
            "additionalProperties": .bool(false)
        ])
    }
}
