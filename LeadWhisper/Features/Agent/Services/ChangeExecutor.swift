import Foundation
import OSLog

@MainActor
struct ChangeExecutor {
    private let repository: CRMRepository

    init(repository: CRMRepository) {
        self.repository = repository
    }

    func apply(_ draft: AgentDraft, transcript: String) throws -> ChangeExecutionResult {
        if let clarification = draft.clarification {
            AppLog.executor.warning("ChangeExecutor blocked by clarification question=\(clarification.question, privacy: .private)")
            throw AgentDraftError.clarificationRequired(clarification.question)
        }

        guard !draft.proposedChanges.isEmpty else {
            AppLog.executor.warning("ChangeExecutor rejected empty draft")
            throw AgentDraftError.emptyDraft
        }

        AppLog.executor.info("Applying draft changes=\(draft.proposedChanges.count, privacy: .public) transcriptCharacters=\(transcript.count, privacy: .public)")

        var changedTitles: [String] = []
        var touchedContact: Contact?
        var touchedOpportunity: Opportunity?
        var collectedTags: [String] = []

        for change in draft.proposedChanges {
            collectedTags = collectedTags.mergingTags(change.tags)
            AppLog.executor.debug("Applying proposed change action=\(change.action.rawValue, privacy: .public) title=\(change.title, privacy: .private) targetID=\(change.targetID ?? "-", privacy: .public)")

            switch change.action {
            case .createContact, .updateContact:
                let contact = try findOrCreateContact(from: change)
                update(contact, from: change)
                touchedContact = contact
                changedTitles.append(change.title)
                addActivity(title: change.title, detail: contact.fullName, entityKind: .contact, entityID: contact.id)

            case .createOpportunity:
                let contact = try findOrCreateContact(from: change)
                let opportunity = try findOrCreateOpportunity(from: change, contact: contact)
                update(opportunity, from: change)
                touchedContact = contact
                touchedOpportunity = opportunity
                changedTitles.append(change.title)
                addActivity(title: change.title, detail: opportunity.title, entityKind: .opportunity, entityID: opportunity.id)

            case .updateOpportunityStage:
                if let opportunity = try findOpportunity(from: change, fallbackContact: touchedContact) {
                    if let stage = OpportunityStage.from(change.stage) {
                        opportunity.stage = stage
                    }
                    appendNote(change.notes, to: &opportunity.notes)
                    opportunity.updatedAt = .now
                    touchedOpportunity = opportunity
                    changedTitles.append(change.title)
                    addActivity(title: change.title, detail: opportunity.stage.title, entityKind: .opportunity, entityID: opportunity.id)
                } else {
                    AppLog.executor.warning("Skipped opportunity stage update because no opportunity matched title=\(change.opportunityTitle ?? "-", privacy: .private) company=\(change.company ?? "-", privacy: .private)")
                }

            case .createFollowUp:
                let contact = try findOrCreateContact(from: change)
                let opportunity = try findOpportunity(from: change, fallbackContact: contact) ?? touchedOpportunity
                let task = FollowUpTask(
                    contact: contact,
                    opportunity: opportunity,
                    title: change.followUpTitle?.nilIfBlank ?? change.title,
                    dueDate: DueDateResolver.date(from: change.dueDateText),
                    dueDateText: change.dueDateText ?? "",
                    notes: change.notes ?? ""
                )
                repository.insert(task)
                touchedContact = contact
                touchedOpportunity = opportunity
                changedTitles.append(change.title)
                addActivity(title: change.title, detail: task.title, entityKind: .followUp, entityID: task.id)

            case .updateFollowUp:
                let contact = try repository.contact(id: change.targetID) ?? repository.contact(named: change.contactName, company: change.company)
                let opportunity = try findOpportunity(from: change, fallbackContact: contact) ?? touchedOpportunity
                if let task = try repository.followUp(id: change.targetID) ??
                    repository.openFollowUp(contactID: contact?.id, opportunityID: opportunity?.id, query: change.followUpTitle ?? change.contactName ?? change.company ?? "") {
                    task.dueDate = DueDateResolver.date(from: change.dueDateText) ?? task.dueDate
                    task.dueDateText = change.dueDateText ?? task.dueDateText
                    appendNote(change.notes, to: &task.notes)
                    task.updatedAt = .now
                    touchedContact = contact ?? touchedContact
                    touchedOpportunity = opportunity
                    changedTitles.append(change.title)
                    addActivity(title: change.title, detail: task.title, entityKind: .followUp, entityID: task.id)
                } else {
                    AppLog.executor.warning("Skipped follow-up update because no open task matched title=\(change.followUpTitle ?? "-", privacy: .private) contact=\(change.contactName ?? "-", privacy: .private)")
                }

            case .archiveFollowUps:
                let opportunity = try findOpportunity(from: change, fallbackContact: touchedContact) ?? touchedOpportunity
                let tasks = try repository.openFollowUps().filter {
                    opportunity == nil || $0.opportunity?.id == opportunity?.id
                }
                for task in tasks {
                    task.state = .archived
                    task.updatedAt = .now
                }
                touchedOpportunity = opportunity
                changedTitles.append(change.title)
                addActivity(title: change.title, detail: "\(tasks.count) follow-up(s) archived", entityKind: .followUp, entityID: opportunity?.id)
                AppLog.executor.info("Archived related follow-ups count=\(tasks.count, privacy: .public) opportunityID=\(opportunity?.id.uuidString ?? "-", privacy: .public)")

            case .createInteraction:
                changedTitles.append(change.title)
                AppLog.executor.debug("Interaction will be created after proposed changes")
            }
        }

        let interaction = Interaction(
            contact: touchedContact,
            opportunity: touchedOpportunity,
            summary: draft.summary.nilIfBlank ?? "Voice CRM update",
            transcript: transcript,
            tags: collectedTags
        )
        repository.insert(interaction)
        addActivity(title: "Activity log added", detail: interaction.summary, entityKind: .interaction, entityID: interaction.id)

        try repository.save()
        AppLog.executor.info("Draft applied changedTitles=\(changedTitles.count, privacy: .public) interactionID=\(interaction.id.uuidString, privacy: .public)")

        return ChangeExecutionResult(
            spokenSummary: draft.spokenConfirmation.nilIfBlank ?? "Done. I saved the CRM updates locally.",
            changedTitles: changedTitles
        )
    }

    private func findOrCreateContact(from change: ProposedChange) throws -> Contact {
        if let contact = try repository.contact(id: change.targetID) {
            AppLog.executor.debug("Found contact by targetID id=\(contact.id.uuidString, privacy: .public)")
            return contact
        }

        if let contact = try repository.contact(named: change.contactName, company: change.company) {
            AppLog.executor.debug("Found contact by name id=\(contact.id.uuidString, privacy: .public) name=\(contact.fullName, privacy: .private)")
            return contact
        }

        let contact = Contact(
            fullName: change.contactName?.nilIfBlank ?? "Unknown Contact",
            company: change.company ?? "",
            notes: change.notes ?? "",
            tags: change.tags
        )
        repository.insert(contact)
        AppLog.executor.info("Created contact id=\(contact.id.uuidString, privacy: .public) name=\(contact.fullName, privacy: .private)")
        return contact
    }

    private func update(_ contact: Contact, from change: ProposedChange) {
        if let name = change.contactName?.nilIfBlank {
            contact.fullName = name
        }
        if let company = change.company?.nilIfBlank {
            contact.company = company
        }
        appendNote(change.notes, to: &contact.notes)
        contact.tags = contact.tags.mergingTags(change.tags)
        contact.updatedAt = .now
    }

    private func findOrCreateOpportunity(from change: ProposedChange, contact: Contact?) throws -> Opportunity {
        if let opportunity = try findOpportunity(from: change, fallbackContact: contact) {
            AppLog.executor.debug("Found opportunity id=\(opportunity.id.uuidString, privacy: .public) title=\(opportunity.title, privacy: .private)")
            return opportunity
        }

        let opportunity = Opportunity(
            title: change.opportunityTitle?.nilIfBlank ?? "New Opportunity",
            company: change.company?.nilIfBlank ?? contact?.company ?? "",
            contact: contact
        )
        repository.insert(opportunity)
        AppLog.executor.info("Created opportunity id=\(opportunity.id.uuidString, privacy: .public) title=\(opportunity.title, privacy: .private)")
        return opportunity
    }

    private func findOpportunity(from change: ProposedChange, fallbackContact: Contact?) throws -> Opportunity? {
        if let opportunity = try repository.opportunity(id: change.targetID) {
            return opportunity
        }

        return try repository.opportunity(
            title: change.opportunityTitle,
            company: change.company ?? fallbackContact?.company,
            contactID: fallbackContact?.id
        )
    }

    private func update(_ opportunity: Opportunity, from change: ProposedChange) {
        if let title = change.opportunityTitle?.nilIfBlank {
            opportunity.title = title
        }
        if let company = change.company?.nilIfBlank {
            opportunity.company = company
        }
        if let stage = OpportunityStage.from(change.stage) {
            opportunity.stage = stage
        }
        if let estimatedValue = change.estimatedValueEUR {
            opportunity.estimatedValueEUR = estimatedValue
        }
        if let budgetText = change.budgetText?.nilIfBlank {
            opportunity.budgetText = budgetText
        }
        if let expectedStart = change.expectedStart?.nilIfBlank {
            opportunity.expectedStart = expectedStart
        }
        appendNote(change.notes, to: &opportunity.notes)
        opportunity.tags = opportunity.tags.mergingTags(change.tags)
        opportunity.updatedAt = .now
    }

    private func appendNote(_ note: String?, to notes: inout String) {
        guard let note = note?.nilIfBlank else { return }
        if notes.isEmpty {
            notes = note
        } else if !notes.searchKey.contains(note.searchKey) {
            notes += "\n\(note)"
        }
    }

    private func addActivity(title: String, detail: String, entityKind: ActivityEntityKind, entityID: UUID?) {
        repository.insert(ActivityEvent(title: title, detail: detail, entityKind: entityKind, entityID: entityID))
    }
}
