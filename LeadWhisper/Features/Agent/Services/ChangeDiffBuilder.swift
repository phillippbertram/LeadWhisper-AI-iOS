import Foundation
import OSLog

/// Resolves the records a draft targets and produces old -> new field diffs so
/// review cards show what an update actually changes. Read-only; resolution
/// mirrors `ChangeExecutor` (targetID first, then name-based lookup).
@MainActor
struct ChangeDiffBuilder {
    private let repository: CRMRepository

    init(repository: CRMRepository) {
        self.repository = repository
    }

    func diffs(for changes: [ProposedChange]) -> [String: [ProposedChangeDiffField]] {
        var result: [String: [ProposedChangeDiffField]] = [:]
        for change in changes {
            if let fields = diff(for: change), !fields.isEmpty {
                result[change.id] = fields
            }
        }
        return result
    }

    private func diff(for change: ProposedChange) -> [ProposedChangeDiffField]? {
        do {
            switch change.action {
            case .updateContact:
                guard let contact = try resolveContact(change) else { return nil }
                return contactFields(change, current: contact)

            case .updateOpportunity, .updateOpportunityStage:
                guard let opportunity = try resolveOpportunity(change) else { return nil }
                return opportunityFields(change, current: opportunity)

            case .updateFollowUp, .completeFollowUp:
                guard let task = try resolveFollowUp(change) else { return nil }
                return followUpFields(change, current: task)

            case .createContact, .createOpportunity, .createInteraction, .createFollowUp,
                 .archiveFollowUps, .deleteContact, .deleteOpportunity, .deleteFollowUp:
                return nil
            }
        } catch {
            AppLog.agent.debug("Change diff lookup failed action=\(change.action.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func resolveContact(_ change: ProposedChange) throws -> Contact? {
        if let contact = try repository.contact(id: change.targetID) {
            return contact
        }
        return try repository.contact(named: change.contactName, company: change.company)
    }

    private func resolveOpportunity(_ change: ProposedChange) throws -> Opportunity? {
        if let opportunity = try repository.opportunity(id: change.targetID) {
            return opportunity
        }
        return try repository.opportunity(title: change.opportunityTitle, company: change.company)
    }

    private func resolveFollowUp(_ change: ProposedChange) throws -> FollowUpTask? {
        if let task = try repository.followUp(id: change.targetID) {
            return task
        }

        guard let titleKey = change.followUpTitle?.searchKey.nilIfBlank else { return nil }
        let matches = try repository.followUps().filter {
            $0.title.searchKey.contains(titleKey) || titleKey.contains($0.title.searchKey)
        }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    private func contactFields(_ change: ProposedChange, current contact: Contact) -> [ProposedChangeDiffField] {
        var fields: [ProposedChangeDiffField] = []
        append(&fields, title: "Contact", old: contact.fullName, new: change.contactName)
        append(&fields, title: "Company", old: contact.company, new: change.company)
        append(&fields, title: "Role", old: contact.role, new: change.role)
        append(&fields, title: "Email", old: contact.email, new: change.email)
        append(&fields, title: "Phone", old: contact.phone, new: change.phone)
        return fields
    }

    private func opportunityFields(_ change: ProposedChange, current opportunity: Opportunity) -> [ProposedChangeDiffField] {
        var fields: [ProposedChangeDiffField] = []
        append(&fields, title: "Opportunity", old: opportunity.title, new: change.opportunityTitle)
        append(&fields, title: "Company", old: opportunity.company, new: change.company)
        if let stage = OpportunityStage.from(change.stage) {
            append(&fields, title: "Stage", old: opportunity.stage.title, new: stage.title)
        }
        if let value = change.estimatedValueEUR {
            append(&fields, title: "Value", old: opportunity.estimatedValueEUR.map(Self.euro) ?? opportunity.budgetText, new: Self.euro(value))
        } else {
            append(&fields, title: "Budget", old: opportunity.budgetText, new: change.budgetText)
        }
        append(&fields, title: "Start", old: opportunity.expectedStart, new: change.expectedStart)
        return fields
    }

    private func followUpFields(_ change: ProposedChange, current task: FollowUpTask) -> [ProposedChangeDiffField] {
        var fields: [ProposedChangeDiffField] = []
        append(&fields, title: "Follow-up", old: task.title, new: change.followUpTitle)
        append(&fields, title: "Due", old: task.dueDateText, new: change.dueDateText)

        let newState = change.followUpState.flatMap(FollowUpState.init) ?? (change.action == .completeFollowUp ? .done : nil)
        if let newState {
            append(&fields, title: "State", old: task.state.title, new: newState.title)
        }
        return fields
    }

    /// Adds a row when the change proposes a value; the old value is only kept
    /// when the record actually differs, so unchanged fields render plainly.
    private func append(_ fields: inout [ProposedChangeDiffField], title: String, old: String, new: String?) {
        guard let new = new?.nilIfBlank else { return }
        let oldValue = old.nilIfBlank
        let isSame = oldValue.map { $0.searchKey == new.searchKey } ?? false
        fields.append(ProposedChangeDiffField(title: title, oldValue: isSame ? nil : oldValue, newValue: new))
    }

    private static func euro(_ value: Int) -> String {
        value.formatted(.currency(code: "EUR").precision(.fractionLength(0)))
    }
}
