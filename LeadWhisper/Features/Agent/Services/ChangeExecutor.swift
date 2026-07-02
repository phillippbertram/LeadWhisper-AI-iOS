import Foundation
import OSLog

@MainActor
struct ChangeExecutor {
    private let repository: CRMRepository

    init(repository: CRMRepository) {
        self.repository = repository
    }

    func apply(_ draft: AgentDraft, transcript: String, allowDestructive: Bool = false) throws -> ChangeExecutionResult {
        if let clarification = draft.clarification {
            AppLog.executor.warning("ChangeExecutor blocked by clarification question=\(clarification.question, privacy: .private)")
            throw AgentDraftError.clarificationRequired(clarification.question)
        }

        guard !draft.proposedChanges.isEmpty else {
            AppLog.executor.warning("ChangeExecutor rejected empty draft")
            throw AgentDraftError.emptyDraft
        }

        guard allowDestructive || !draft.containsDestructiveChange else {
            AppLog.executor.warning("ChangeExecutor blocked destructive draft without confirmation")
            throw AgentDraftError.destructiveConfirmationRequired
        }

        AppLog.executor.info("Applying draft changes=\(draft.proposedChanges.count, privacy: .public) transcriptCharacters=\(transcript.count, privacy: .public)")

        var changedRecords: [ChangedCRMRecord] = []
        var touchedContact: Contact?
        var touchedOpportunity: Opportunity?
        var collectedTags: [String] = []
        var didRequestInteraction = false

        func record(_ title: String, kind: ActivityEntityKind, id: UUID, canOpen: Bool = true) {
            if let index = changedRecords.firstIndex(where: { $0.kind == kind && $0.id == id }) {
                changedRecords[index].title = title
                changedRecords[index].canOpen = changedRecords[index].canOpen && canOpen
            } else {
                changedRecords.append(ChangedCRMRecord(id: id, kind: kind, title: title, canOpen: canOpen))
            }
        }

        for change in draft.proposedChanges {
            collectedTags = collectedTags.mergingTags(change.tags)
            AppLog.executor.debug("Applying proposed change action=\(change.action.rawValue, privacy: .public) title=\(change.title, privacy: .private) targetID=\(change.targetID ?? "-", privacy: .public)")

            switch change.action {
            case .createContact, .updateContact:
                let contact = try findOrCreateContact(from: change)
                update(contact, from: change)
                touchedContact = contact
                record(contact.fullName, kind: .contact, id: contact.id)
                addActivity(title: change.title, detail: contact.fullName, entityKind: .contact, entityID: contact.id)

            case .createOpportunity:
                let contact = try findOrCreateContact(from: change)
                let opportunity = try findOrCreateOpportunity(from: change, contact: contact)
                update(opportunity, from: change)
                touchedContact = contact
                touchedOpportunity = opportunity
                record(contact.fullName, kind: .contact, id: contact.id)
                record(opportunity.title, kind: .opportunity, id: opportunity.id)
                addActivity(title: change.title, detail: opportunity.title, entityKind: .opportunity, entityID: opportunity.id)

            case .updateOpportunity:
                let contact = try repository.contact(named: change.contactName, company: change.company)
                if let opportunity = try findOpportunity(from: change, fallbackContact: contact ?? touchedContact) {
                    update(opportunity, from: change)
                    touchedContact = contact ?? touchedContact
                    touchedOpportunity = opportunity
                    record(opportunity.title, kind: .opportunity, id: opportunity.id)
                    addActivity(title: change.title, detail: opportunity.title, entityKind: .opportunity, entityID: opportunity.id)
                } else {
                    AppLog.executor.warning("Skipped opportunity update because no opportunity matched title=\(change.opportunityTitle ?? "-", privacy: .private) company=\(change.company ?? "-", privacy: .private)")
                }

            case .updateOpportunityStage:
                if let opportunity = try findOpportunity(from: change, fallbackContact: touchedContact) {
                    if let stage = OpportunityStage.from(change.stage) {
                        opportunity.stage = stage
                    }
                    appendNote(change.notes, to: &opportunity.notes)
                    opportunity.updatedAt = .now
                    touchedOpportunity = opportunity
                    record(opportunity.title, kind: .opportunity, id: opportunity.id)
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
                record(contact.fullName, kind: .contact, id: contact.id)
                record(task.title, kind: .followUp, id: task.id)
                addActivity(title: change.title, detail: task.title, entityKind: .followUp, entityID: task.id)

            case .updateFollowUp:
                let contact = try repository.contact(named: change.contactName, company: change.company)
                let opportunity = try findOpportunity(from: change, fallbackContact: contact) ?? touchedOpportunity
                if let task = try findUniqueFollowUp(from: change, fallbackContact: contact, fallbackOpportunity: opportunity) {
                    update(task, from: change)
                    task.updatedAt = .now
                    touchedContact = contact ?? touchedContact
                    touchedOpportunity = opportunity
                    record(task.title, kind: .followUp, id: task.id)
                    addActivity(title: change.title, detail: task.title, entityKind: .followUp, entityID: task.id)
                } else {
                    AppLog.executor.warning("Skipped follow-up update because no open task matched title=\(change.followUpTitle ?? "-", privacy: .private) contact=\(change.contactName ?? "-", privacy: .private)")
                }

            case .completeFollowUp:
                if let task = try findUniqueFollowUp(from: change, fallbackContact: touchedContact, fallbackOpportunity: touchedOpportunity) {
                    task.state = .done
                    task.updatedAt = .now
                    touchedContact = task.contact ?? touchedContact
                    touchedOpportunity = task.opportunity ?? touchedOpportunity
                    record(task.title, kind: .followUp, id: task.id)
                    addActivity(title: change.title, detail: task.title, entityKind: .followUp, entityID: task.id)
                } else {
                    AppLog.executor.warning("Skipped follow-up completion because no task matched title=\(change.followUpTitle ?? "-", privacy: .private) contact=\(change.contactName ?? "-", privacy: .private)")
                }

            case .archiveFollowUps:
                let opportunity = try findOpportunity(from: change, fallbackContact: touchedContact) ?? touchedOpportunity
                let tasks = try repository.openFollowUps().filter {
                    opportunity == nil || $0.opportunity?.id == opportunity?.id
                }
                for task in tasks {
                    task.state = .archived
                    task.updatedAt = .now
                    record(task.title, kind: .followUp, id: task.id)
                }
                touchedOpportunity = opportunity
                addActivity(title: change.title, detail: "\(tasks.count) follow-up(s) archived", entityKind: .followUp, entityID: opportunity?.id)
                AppLog.executor.info("Archived related follow-ups count=\(tasks.count, privacy: .public) opportunityID=\(opportunity?.id.uuidString ?? "-", privacy: .public)")

            case .createInteraction:
                didRequestInteraction = true
                AppLog.executor.debug("Interaction will be created after proposed changes")

            case .deleteContact:
                let contact = try findRequiredContactForDelete(from: change)
                record(contact.fullName, kind: .contact, id: contact.id, canOpen: false)
                repository.stageDeleteContact(contact)

            case .deleteOpportunity:
                let opportunity = try findRequiredOpportunityForDelete(from: change, fallbackContact: touchedContact)
                record(opportunity.title, kind: .opportunity, id: opportunity.id, canOpen: false)
                repository.stageDeleteOpportunity(opportunity)

            case .deleteFollowUp:
                let task = try findRequiredFollowUpForDelete(from: change, fallbackContact: touchedContact, fallbackOpportunity: touchedOpportunity)
                record(task.title, kind: .followUp, id: task.id, canOpen: false)
                repository.stageDeleteFollowUp(task)
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
        if didRequestInteraction, changedRecords.isEmpty {
            record(interaction.summary, kind: .interaction, id: interaction.id)
        }

        try repository.save()
        AppLog.executor.info("Draft applied changedRecords=\(changedRecords.count, privacy: .public) interactionID=\(interaction.id.uuidString, privacy: .public)")

        return ChangeExecutionResult(
            spokenSummary: draft.spokenConfirmation.nilIfBlank ?? "Done. I saved the CRM updates locally.",
            changedRecords: changedRecords
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

        guard let contactName = change.contactName?.nilIfBlank else {
            throw AgentDraftError.unsafeDestructiveChange("I need a real contact name before saving this draft.")
        }

        let contact = Contact(
            fullName: contactName,
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
        if let role = change.role?.nilIfBlank {
            contact.role = role
        }
        if let email = change.email?.nilIfBlank {
            contact.email = email
        }
        if let phone = change.phone?.nilIfBlank {
            contact.phone = phone
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

        guard let opportunityTitle = change.opportunityTitle?.nilIfBlank else {
            throw AgentDraftError.unsafeDestructiveChange("I need a real opportunity title before saving this draft.")
        }

        let opportunity = Opportunity(
            title: opportunityTitle,
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

    private func findRequiredOpportunityForDelete(from change: ProposedChange, fallbackContact: Contact?) throws -> Opportunity {
        if let opportunity = try repository.opportunity(id: change.targetID) {
            return opportunity
        }

        let contact = try repository.contact(named: change.contactName, company: change.company) ?? fallbackContact
        let matches = try matchingOpportunities(from: change, fallbackContact: contact)
        guard matches.count == 1, let opportunity = matches.first else {
            throw AgentDraftError.unsafeDestructiveChange("I could not safely find exactly one opportunity to delete.")
        }
        return opportunity
    }

    private func matchingOpportunities(from change: ProposedChange, fallbackContact: Contact?) throws -> [Opportunity] {
        let titleKey = change.opportunityTitle?.searchKey ?? ""
        let companyKey = (change.company ?? fallbackContact?.company)?.searchKey ?? ""
        guard !titleKey.isEmpty || !companyKey.isEmpty || fallbackContact != nil else { return [] }

        return try repository.opportunities().filter { opportunity in
            let titleMatches = titleKey.isEmpty ||
                opportunity.title.searchKey == titleKey ||
                opportunity.title.searchKey.contains(titleKey) ||
                titleKey.contains(opportunity.title.searchKey)
            let companyMatches = companyKey.isEmpty ||
                opportunity.company.searchKey == companyKey ||
                opportunity.company.searchKey.contains(companyKey)
            let contactMatches = fallbackContact == nil || opportunity.contact?.id == fallbackContact?.id
            return titleMatches && companyMatches && contactMatches
        }
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

    private func update(_ task: FollowUpTask, from change: ProposedChange) {
        if let title = change.followUpTitle?.nilIfBlank {
            task.title = title
        }
        if let dueDateText = change.dueDateText?.nilIfBlank {
            task.dueDate = DueDateResolver.date(from: dueDateText) ?? task.dueDate
            task.dueDateText = dueDateText
        }
        if let state = followUpState(from: change.followUpState) {
            task.state = state
        }
        appendNote(change.notes, to: &task.notes)
        task.updatedAt = .now
    }

    private func findRequiredContactForDelete(from change: ProposedChange) throws -> Contact {
        if let contact = try repository.contact(id: change.targetID) {
            return contact
        }

        let query = change.contactName?.nilIfBlank ?? change.company?.nilIfBlank ?? ""
        guard !query.isEmpty else {
            throw AgentDraftError.unsafeDestructiveChange("I need a contact name or company before deleting a contact.")
        }

        let companyKey = change.company?.searchKey ?? ""
        let matches = try repository.contacts(matching: query).filter {
            companyKey.isEmpty || $0.company.searchKey == companyKey || $0.company.searchKey.contains(companyKey)
        }
        guard matches.count == 1, let contact = matches.first else {
            throw AgentDraftError.unsafeDestructiveChange("I could not safely find exactly one contact to delete.")
        }
        return contact
    }

    private func findRequiredFollowUpForDelete(from change: ProposedChange, fallbackContact: Contact?, fallbackOpportunity: Opportunity?) throws -> FollowUpTask {
        guard let task = try findUniqueFollowUp(from: change, fallbackContact: fallbackContact, fallbackOpportunity: fallbackOpportunity) else {
            throw AgentDraftError.unsafeDestructiveChange("I could not safely find exactly one follow-up to delete.")
        }
        return task
    }

    private func findUniqueFollowUp(from change: ProposedChange, fallbackContact: Contact?, fallbackOpportunity: Opportunity?) throws -> FollowUpTask? {
        if let task = try repository.followUp(id: change.targetID) {
            return task
        }

        let matches = try matchingFollowUps(from: change, fallbackContact: fallbackContact, fallbackOpportunity: fallbackOpportunity)
        guard matches.count <= 1 else {
            throw AgentDraftError.unsafeDestructiveChange("I found more than one matching follow-up. Please clarify which one to change.")
        }
        return matches.first
    }

    private func matchingFollowUps(from change: ProposedChange, fallbackContact: Contact?, fallbackOpportunity: Opportunity?) throws -> [FollowUpTask] {
        let contact = try repository.contact(named: change.contactName, company: change.company) ?? fallbackContact
        let opportunity = try findOpportunity(from: change, fallbackContact: contact) ?? fallbackOpportunity
        let queryKey = (change.followUpTitle ?? change.contactName ?? change.company ?? change.dueDateText ?? "").searchKey

        guard !queryKey.isEmpty || contact != nil || opportunity != nil else { return [] }

        return try repository.followUps().filter { task in
            let contactMatches = contact == nil || task.contact?.id == contact?.id
            let opportunityMatches = opportunity == nil || task.opportunity?.id == opportunity?.id
            let queryMatches = queryKey.isEmpty ||
                task.title.searchKey.contains(queryKey) ||
                task.notes.searchKey.contains(queryKey) ||
                task.dueDateText.searchKey.contains(queryKey)
            return contactMatches && opportunityMatches && queryMatches
        }
    }

    private func followUpState(from value: String?) -> FollowUpState? {
        guard let value = value?.nilIfBlank else { return nil }
        if let state = FollowUpState(rawValue: value) {
            return state
        }

        let key = value.searchKey
        if key.contains("done") || key.contains("complete") || key.contains("erledigt") {
            return .done
        }
        if key.contains("archive") || key.contains("archiv") {
            return .archived
        }
        if key.contains("open") || key.contains("offen") {
            return .open
        }
        return nil
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
