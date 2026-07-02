import Foundation
import FoundationModels
import OSLog

@Generable(description: "Arguments for looking up contacts in the local CRM.")
struct FindContactsArguments: Sendable {
    @Guide(description: "Short name, company, or keyword.")
    var query: String

    init(query: String) {
        self.query = query
    }
}

@Generable(description: "Arguments for looking up opportunities in the local CRM.")
struct FindOpportunitiesArguments: Sendable {
    @Guide(description: "Short title, company, stage, or keyword.")
    var query: String

    init(query: String) {
        self.query = query
    }
}

@Generable(description: "Arguments for looking up follow-up tasks in the local CRM.")
struct FindFollowUpsArguments: Sendable {
    @Guide(description: "Short contact, title, date, or keyword.")
    var query: String

    init(query: String) {
        self.query = query
    }
}

/// Thrown by the engine's budget wrapper instead of running another lookup.
/// This must escape the tool call so the app can end the turn immediately.
struct AgentToolBudgetExceeded: LocalizedError {
    var reason: String

    var errorDescription: String? {
        "Agent tool budget exceeded. \(reason)"
    }
}

struct AgentTurnTimeout: Error {}

struct FindContactsTool: Tool {
    let dataSource: AgentToolDataSource

    var name: String { "findContacts" }
    var description: String {
        "Search existing local CRM contacts by combined fuzzy name, company, notes, or tags. This tool is read-only."
    }

    @concurrent
    func call(arguments: FindContactsArguments) async throws -> String {
        let key = arguments.query.searchKey
        guard !key.isEmpty else {
            AppLog.tools.warning("findContacts rejected empty query")
            return ToolText.emptyQuery
        }

        let matches = try await dataSource.contacts(arguments.query, ToolText.resultLimit)
        AppLog.tools.debug("findContacts query=\(arguments.query, privacy: .private) returned=\(matches.count, privacy: .public)")
        return ToolText.contacts(matches)
    }
}

struct FindOpportunitiesTool: Tool {
    let dataSource: AgentToolDataSource

    var name: String { "findOpportunities" }
    var description: String {
        "Search existing local CRM opportunities by combined fuzzy title, company, stage, budget, notes, or tags. This tool is read-only."
    }

    @concurrent
    func call(arguments: FindOpportunitiesArguments) async throws -> String {
        let key = arguments.query.searchKey
        guard !key.isEmpty else {
            AppLog.tools.warning("findOpportunities rejected empty query")
            return ToolText.emptyQuery
        }

        let matches = try await dataSource.opportunities(arguments.query, ToolText.resultLimit)
        AppLog.tools.debug("findOpportunities query=\(arguments.query, privacy: .private) returned=\(matches.count, privacy: .public)")
        return ToolText.opportunities(matches)
    }
}

@Generable(description: "Arguments for reading one contact's full local CRM details.")
struct ContactDetailsArguments: Sendable {
    @Guide(description: "Contact name or company to look up.")
    var query: String

    init(query: String) {
        self.query = query
    }
}

struct GetContactDetailsTool: Tool {
    let dataSource: AgentToolDataSource

    var name: String { "getContactDetails" }
    var description: String {
        "Read one contact's full local details: role, email, phone, notes, tags, opportunities, and open follow-ups. This tool is read-only."
    }

    @concurrent
    func call(arguments: ContactDetailsArguments) async throws -> String {
        let key = arguments.query.searchKey
        guard !key.isEmpty else {
            AppLog.tools.warning("getContactDetails rejected empty query")
            return ToolText.emptyQuery
        }

        let snapshot = try await dataSource.snapshot()
        AppLog.tools.debug("getContactDetails query=\(arguments.query, privacy: .private)")
        return ToolText.contactDetails(snapshot, query: arguments.query)
    }
}

@Generable(description: "Arguments for summarizing the local CRM pipeline.")
struct PipelineSummaryArguments: Sendable {
    @Guide(description: "Optional focus: contacts, opportunities, or followUps.")
    var focus: String?
}

struct GetPipelineSummaryTool: Tool {
    let dataSource: AgentToolDataSource

    var name: String { "getPipelineSummary" }
    var description: String {
        "Summarize the local CRM: contact count, opportunities per stage, and open follow-ups with due dates. This tool is read-only."
    }

    @concurrent
    func call(arguments: PipelineSummaryArguments) async throws -> String {
        let snapshot = try await dataSource.snapshot()
        AppLog.tools.debug("getPipelineSummary focus=\(arguments.focus ?? "-", privacy: .public) contacts=\(snapshot.contacts.count, privacy: .public) opportunities=\(snapshot.opportunities.count, privacy: .public) followUps=\(snapshot.followUps.count, privacy: .public)")
        return ToolText.pipelineSummary(snapshot, focus: arguments.focus)
    }
}

struct FindFollowUpsTool: Tool {
    let dataSource: AgentToolDataSource

    var name: String { "findFollowUps" }
    var description: String {
        "Search existing local CRM follow-up tasks by combined fuzzy title, due date text, notes, state, contact, or opportunity. This tool is read-only."
    }

    @concurrent
    func call(arguments: FindFollowUpsArguments) async throws -> String {
        let key = arguments.query.searchKey
        guard !key.isEmpty else {
            AppLog.tools.warning("findFollowUps rejected empty query")
            return ToolText.emptyQuery
        }

        let matches = try await dataSource.followUps(arguments.query, ToolText.resultLimit)
        AppLog.tools.debug("findFollowUps query=\(arguments.query, privacy: .private) returned=\(matches.count, privacy: .public)")
        return ToolText.followUps(matches)
    }
}

enum ToolText {
    nonisolated static var resultLimit: Int { 5 }
    nonisolated static var emptyQuery: String { "No query supplied. Ask for a specific name, company, opportunity, or follow-up." }
    private nonisolated static var noMatches: String { "No matching local records." }

    nonisolated static func contacts(_ contacts: [CRMContactSnapshot]) -> String {
        guard !contacts.isEmpty else { return noMatches }
        return contacts.map {
            "contact id=\($0.id) name=\($0.fullName.compactToolValue) company=\($0.company.compactToolValue) role=\($0.role.compactToolValue) email=\($0.email.compactToolValue) phone=\($0.phone.compactToolValue) tags=\($0.tags.toolList)"
        }
        .joined(separator: "\n")
    }

    nonisolated static func opportunities(_ opportunities: [CRMOpportunitySnapshot]) -> String {
        guard !opportunities.isEmpty else { return noMatches }
        return opportunities.map {
            let value = $0.estimatedValueEUR.map { String($0) } ?? $0.budgetText.compactToolValue
            return "opportunity id=\($0.id) title=\($0.title.compactToolValue) company=\($0.company.compactToolValue) stage=\($0.stage) value=\(value) tags=\($0.tags.toolList)"
        }
        .joined(separator: "\n")
    }

    nonisolated static func followUps(_ followUps: [CRMFollowUpSnapshot]) -> String {
        guard !followUps.isEmpty else { return noMatches }
        return followUps.map {
            "followUp id=\($0.id) title=\($0.title.compactToolValue) due=\($0.dueDateText.compactToolValue) state=\($0.state) notes=\($0.notes.compactToolValue)"
        }
        .joined(separator: "\n")
    }

    nonisolated static func contactDetails(_ snapshot: CRMDataSnapshot, query: String) -> String {
        let key = query.searchKey
        let matches = snapshot.contacts.filter {
            $0.fullName.searchKey.contains(key) ||
                key.contains($0.fullName.searchKey) ||
                (!$0.company.searchKey.isEmpty && $0.company.searchKey.contains(key))
        }

        guard let contact = matches.first else { return noMatches }
        guard matches.count == 1 else {
            return "Multiple contacts match. Ask which one:\n" + contacts(Array(matches.prefix(resultLimit)))
        }

        var lines = [contacts([contact])]
        if let notes = contact.notes.nilIfBlank {
            lines.append("notes=\(String(notes.prefix(160)))")
        }

        let related = snapshot.opportunities.filter { $0.contactID == contact.id }
        if !related.isEmpty {
            lines.append(opportunities(Array(related.prefix(3))))
        }

        let open = snapshot.followUps.filter { $0.contactID == contact.id && $0.state == FollowUpState.open.rawValue }
        if !open.isEmpty {
            lines.append(followUps(Array(open.prefix(3))))
        }

        return lines.joined(separator: "\n")
    }

    nonisolated static func pipelineSummary(_ snapshot: CRMDataSnapshot, focus: String?) -> String {
        let focusKey = focus?.searchKey ?? ""
        let wantsContacts = focusKey.isEmpty || focusKey.contains("contact")
        let wantsOpportunities = focusKey.isEmpty || focusKey.contains("opportun")
        let wantsFollowUps = focusKey.isEmpty || focusKey.contains("follow")

        var lines: [String] = []

        if wantsContacts {
            lines.append("contacts total=\(snapshot.contacts.count)")
        }

        if wantsOpportunities {
            if snapshot.opportunities.isEmpty {
                lines.append("opportunities none")
            } else {
                let byStage = Dictionary(grouping: snapshot.opportunities, by: \.stage)
                let stageCounts = byStage.keys.sorted().map { "\($0)=\(byStage[$0]?.count ?? 0)" }.joined(separator: " ")
                lines.append("opportunities total=\(snapshot.opportunities.count) \(stageCounts)")
            }
        }

        if wantsFollowUps {
            let open = snapshot.followUps.filter { $0.state == FollowUpState.open.rawValue }
            if open.isEmpty {
                lines.append("open followUps none")
            } else {
                lines.append("open followUps total=\(open.count)")
                for followUp in open.prefix(resultLimit) {
                    lines.append("followUp id=\(followUp.id) title=\(followUp.title.compactToolValue) due=\(followUp.dueDateText.compactToolValue)")
                }
            }
        }

        return lines.isEmpty ? "No local CRM data yet." : lines.joined(separator: "\n")
    }
}

private extension String {
    nonisolated var compactToolValue: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 80 else { return trimmed }
        return "\(trimmed.prefix(77))..."
    }
}

private extension Array where Element == String {
    nonisolated var toolList: String {
        let values = prefix(3).map(\.compactToolValue)
        if values.isEmpty {
            return "-"
        }
        return values.joined(separator: ",")
    }
}
