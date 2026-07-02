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

struct FindContactsTool: Tool {
    let contacts: [CRMContactSnapshot]

    var name: String { "findContacts" }
    var description: String {
        "Search existing local CRM contacts by name, company, notes, or tags. This tool is read-only."
    }

    @concurrent
    func call(arguments: FindContactsArguments) async throws -> String {
        let key = arguments.query.searchKey
        guard !key.isEmpty else {
            AppLog.tools.warning("findContacts rejected empty query")
            return ToolText.emptyQuery
        }

        let matches = contacts.filter { contact in
            return contact.fullName.searchKey.contains(key) ||
                contact.company.searchKey.contains(key) ||
                contact.notes.searchKey.contains(key) ||
                contact.tags.contains { $0.searchKey.contains(key) }
        }
        AppLog.tools.debug("findContacts query=\(arguments.query, privacy: .private) matches=\(matches.count, privacy: .public) returned=\(min(matches.count, ToolText.resultLimit), privacy: .public)")
        return ToolText.contacts(matches.prefix(ToolText.resultLimit))
    }
}

struct FindOpportunitiesTool: Tool {
    let opportunities: [CRMOpportunitySnapshot]

    var name: String { "findOpportunities" }
    var description: String {
        "Search existing local CRM opportunities by title, company, stage, budget, or tags. This tool is read-only."
    }

    @concurrent
    func call(arguments: FindOpportunitiesArguments) async throws -> String {
        let key = arguments.query.searchKey
        guard !key.isEmpty else {
            AppLog.tools.warning("findOpportunities rejected empty query")
            return ToolText.emptyQuery
        }

        let matches = opportunities.filter { opportunity in
            return opportunity.title.searchKey.contains(key) ||
                opportunity.company.searchKey.contains(key) ||
                opportunity.stage.searchKey.contains(key) ||
                opportunity.budgetText.searchKey.contains(key) ||
                opportunity.tags.contains { $0.searchKey.contains(key) }
        }
        AppLog.tools.debug("findOpportunities query=\(arguments.query, privacy: .private) matches=\(matches.count, privacy: .public) returned=\(min(matches.count, ToolText.resultLimit), privacy: .public)")
        return ToolText.opportunities(matches.prefix(ToolText.resultLimit))
    }
}

struct FindFollowUpsTool: Tool {
    let followUps: [CRMFollowUpSnapshot]

    var name: String { "findFollowUps" }
    var description: String {
        "Search existing local CRM follow-up tasks by title, due date text, notes, or state. This tool is read-only."
    }

    @concurrent
    func call(arguments: FindFollowUpsArguments) async throws -> String {
        let key = arguments.query.searchKey
        guard !key.isEmpty else {
            AppLog.tools.warning("findFollowUps rejected empty query")
            return ToolText.emptyQuery
        }

        let matches = followUps.filter { followUp in
            return followUp.title.searchKey.contains(key) ||
                followUp.dueDateText.searchKey.contains(key) ||
                followUp.notes.searchKey.contains(key) ||
                followUp.state.searchKey.contains(key)
        }
        AppLog.tools.debug("findFollowUps query=\(arguments.query, privacy: .private) matches=\(matches.count, privacy: .public) returned=\(min(matches.count, ToolText.resultLimit), privacy: .public)")
        return ToolText.followUps(matches.prefix(ToolText.resultLimit))
    }
}

enum ToolText {
    nonisolated static var resultLimit: Int { 5 }
    nonisolated static var emptyQuery: String { "No query supplied. Ask for a specific name, company, opportunity, or follow-up." }
    private nonisolated static var noMatches: String { "No matching local records." }

    nonisolated static func contacts(_ contacts: ArraySlice<CRMContactSnapshot>) -> String {
        guard !contacts.isEmpty else { return noMatches }
        return contacts.map {
            "contact id=\($0.id) name=\($0.fullName.compactToolValue) company=\($0.company.compactToolValue) tags=\($0.tags.toolList)"
        }
        .joined(separator: "\n")
    }

    nonisolated static func opportunities(_ opportunities: ArraySlice<CRMOpportunitySnapshot>) -> String {
        guard !opportunities.isEmpty else { return noMatches }
        return opportunities.map {
            let value = $0.estimatedValueEUR.map { String($0) } ?? $0.budgetText.compactToolValue
            return "opportunity id=\($0.id) title=\($0.title.compactToolValue) company=\($0.company.compactToolValue) stage=\($0.stage) value=\(value) tags=\($0.tags.toolList)"
        }
        .joined(separator: "\n")
    }

    nonisolated static func followUps(_ followUps: ArraySlice<CRMFollowUpSnapshot>) -> String {
        guard !followUps.isEmpty else { return noMatches }
        return followUps.map {
            "followUp id=\($0.id) title=\($0.title.compactToolValue) due=\($0.dueDateText.compactToolValue) state=\($0.state) notes=\($0.notes.compactToolValue)"
        }
        .joined(separator: "\n")
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
