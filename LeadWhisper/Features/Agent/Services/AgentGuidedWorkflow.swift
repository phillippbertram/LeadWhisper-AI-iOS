import Foundation

struct AgentGuidedWorkflow {
    enum Kind {
        case createContact
        case createFollowUp
        case updateContact
        case deleteContact
        case completeFollowUp
    }

    struct Response {
        var workflow: AgentGuidedWorkflow?
        var result: AgentRunResult
    }

    private struct Slots {
        var contactName: String?
        var company: String?
        var role: String?
        var email: String?
        var phone: String?
        var followUpTitle: String?
        var dueDateText: String?
        var notes: String?
        var targetContact: CRMContactSnapshot?
        var targetFollowUp: CRMFollowUpSnapshot?
        var asksNextStep = false
        var wantsFollowUp: Bool?
        var directCreateContact = false
    }

    private var kind: Kind
    private var slots: Slots

    static func start(
        message: String,
        snapshot: CRMDataSnapshot,
        availabilityMessage: String
    ) -> Response? {
        let key = message.searchKey

        if isCreateContactIntent(key) {
            var workflow = AgentGuidedWorkflow(kind: .createContact, slots: Slots())
            workflow.slots.directCreateContact = key.contains("create contact") ||
                key.contains("add contact") ||
                key.contains("kontakt") && (key.contains("anlegen") || key.contains("erstell") || key.contains("hinzufug"))
            workflow.mergeContactFields(from: message)
            return workflow.advance("", snapshot: snapshot, availabilityMessage: availabilityMessage)
        }

        if isDeleteContactIntent(key) {
            var workflow = AgentGuidedWorkflow(kind: .deleteContact, slots: Slots())
            return workflow.advance(cleanRecordQuery(message), snapshot: snapshot, availabilityMessage: availabilityMessage)
        }

        if isCompleteFollowUpIntent(key) {
            var workflow = AgentGuidedWorkflow(kind: .completeFollowUp, slots: Slots())
            return workflow.advance(cleanRecordQuery(message), snapshot: snapshot, availabilityMessage: availabilityMessage)
        }

        if isCreateFollowUpIntent(key) {
            var workflow = AgentGuidedWorkflow(kind: .createFollowUp, slots: Slots())
            return workflow.advance(message, snapshot: snapshot, availabilityMessage: availabilityMessage)
        }

        if isUpdateContactIntent(key) {
            var workflow = AgentGuidedWorkflow(kind: .updateContact, slots: Slots())
            return workflow.advance(cleanRecordQuery(message), snapshot: snapshot, availabilityMessage: availabilityMessage)
        }

        if snapshot.isEmpty && wantsExistingData(key) {
            return Response(
                workflow: nil,
                result: reply(
                    "There is no local CRM data yet.",
                    detail: "Create a contact or lead first, then I can update, complete, or delete existing records.",
                    availabilityMessage: availabilityMessage
                )
            )
        }

        return nil
    }

    mutating func advance(
        _ message: String,
        snapshot: CRMDataSnapshot,
        availabilityMessage: String
    ) -> Response {
        switch kind {
        case .createContact:
            return advanceCreateContact(message, availabilityMessage: availabilityMessage)
        case .createFollowUp:
            return advanceCreateFollowUp(message, snapshot: snapshot, availabilityMessage: availabilityMessage)
        case .updateContact:
            return advanceUpdateContact(message, snapshot: snapshot, availabilityMessage: availabilityMessage)
        case .deleteContact:
            return advanceDeleteContact(message, snapshot: snapshot, availabilityMessage: availabilityMessage)
        case .completeFollowUp:
            return advanceCompleteFollowUp(message, snapshot: snapshot, availabilityMessage: availabilityMessage)
        }
    }

    private init(kind: Kind, slots: Slots) {
        self.kind = kind
        self.slots = slots
    }

    private mutating func advanceCreateContact(
        _ message: String,
        availabilityMessage: String
    ) -> Response {
        mergeContactFields(from: message)

        guard let contactName = slots.contactName?.nilIfBlank else {
            return ask(
                "Who is the lead or contact?",
                placeholder: "Contact name",
                availabilityMessage: availabilityMessage
            )
        }

        guard let company = slots.company?.nilIfBlank else {
            return ask(
                "Which company is \(contactName) with?",
                placeholder: "Company",
                availabilityMessage: availabilityMessage
            )
        }

        if !slots.directCreateContact && !slots.asksNextStep {
            slots.asksNextStep = true
            return ask(
                "Should I add a next step for \(contactName) as well?",
                options: ["Create contact only", "Add a follow-up"],
                placeholder: "Follow up next week, send proposal, or create contact only",
                availabilityMessage: availabilityMessage
            )
        }

        if slots.asksNextStep, slots.wantsFollowUp == nil {
            let key = message.searchKey
            if key.contains("contact only") || key.contains("only") || key.contains("no") || key.contains("nein") || key.contains("nur") {
                slots.wantsFollowUp = false
            } else if key.contains("add") || key.contains("follow") || key.contains("nachfass") || key.contains("task") || key.contains("aufgabe") || message.nilIfBlank != nil {
                slots.wantsFollowUp = true
                if !key.contains("add a follow-up") {
                    slots.followUpTitle = Self.cleanFollowUpTitle(message)
                    slots.dueDateText = Self.inferDueDateText(from: message)
                }
            }
        }

        if slots.wantsFollowUp == true, slots.followUpTitle?.nilIfBlank == nil {
            return ask(
                "What should the follow-up be?",
                placeholder: "e.g. Send proposal next week",
                availabilityMessage: availabilityMessage
            )
        }

        return proposeCreateContact(contactName: contactName, company: company, availabilityMessage: availabilityMessage)
    }

    private mutating func advanceCreateFollowUp(
        _ message: String,
        snapshot: CRMDataSnapshot,
        availabilityMessage: String
    ) -> Response {
        guard !snapshot.contacts.isEmpty || !snapshot.opportunities.isEmpty else {
            return Response(
                workflow: nil,
                    result: Self.reply(
                    "There are no contacts or opportunities yet.",
                    detail: "Create the lead first, then I can add a follow-up to it.",
                    availabilityMessage: availabilityMessage
                )
            )
        }

        if slots.targetContact == nil {
            let matches = matchingContacts(for: Self.cleanRecordQuery(message), in: snapshot)
            if matches.count == 1 {
                slots.targetContact = matches[0]
                return ask(
                    "What should I remind you to do?",
                    placeholder: "Follow-up title",
                    availabilityMessage: availabilityMessage
                )
            } else if matches.count > 1 {
                return chooseContact(
                    "Which contact should this follow-up belong to?",
                    matches: matches,
                    availabilityMessage: availabilityMessage
                )
            } else {
                return chooseContact(
                    "Who is this follow-up for?",
                    matches: Array(snapshot.contacts.prefix(4)),
                    availabilityMessage: availabilityMessage
                )
            }
        }

        if slots.followUpTitle?.nilIfBlank == nil {
            let title = Self.cleanFollowUpTitle(message)
            if title.searchKey != slots.targetContact?.fullName.searchKey {
                slots.followUpTitle = title
                slots.dueDateText = Self.inferDueDateText(from: message)
            }
        }

        guard slots.followUpTitle?.nilIfBlank != nil else {
            return ask(
                "What should I remind you to do?",
                placeholder: "Follow-up title",
                availabilityMessage: availabilityMessage
            )
        }

        if slots.dueDateText == nil {
            let key = message.searchKey
            if key.contains("no due") || key.contains("without due") || key.contains("kein datum") {
                slots.dueDateText = ""
            } else if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      slots.followUpTitle?.searchKey != message.searchKey,
                      slots.targetContact?.fullName.searchKey != message.searchKey {
                slots.dueDateText = message
            } else {
                return ask(
                    "When should it be due?",
                    options: ["No due date", "Today", "Tomorrow", "Next week"],
                    placeholder: "Due date",
                    availabilityMessage: availabilityMessage
                )
            }
        }

        return proposeCreateFollowUp(availabilityMessage: availabilityMessage)
    }

    private mutating func advanceUpdateContact(
        _ message: String,
        snapshot: CRMDataSnapshot,
        availabilityMessage: String
    ) -> Response {
        guard !snapshot.contacts.isEmpty else {
            return Response(
                workflow: nil,
                    result: Self.reply(
                    "There are no contacts to update yet.",
                    detail: "Create a contact first, then I can update its details.",
                    availabilityMessage: availabilityMessage
                )
            )
        }

        if slots.targetContact == nil {
            let matches = matchingContacts(for: message, in: snapshot)
            if matches.count == 1 {
                slots.targetContact = matches[0]
                return ask(
                    "What should change for \(matches[0].fullName)?",
                    placeholder: "New phone, email, company, role, or note",
                    availabilityMessage: availabilityMessage
                )
            }
            return chooseContact(
                matches.isEmpty ? "Which contact should I update?" : "Which contact did you mean?",
                matches: matches.isEmpty ? Array(snapshot.contacts.prefix(4)) : matches,
                availabilityMessage: availabilityMessage
            )
        }

        mergeUpdateFields(from: message)
        guard hasUpdateFields else {
            return ask(
                "What should change for \(slots.targetContact?.fullName ?? "this contact")?",
                placeholder: "New phone, email, company, role, or note",
                availabilityMessage: availabilityMessage
            )
        }

        return proposeUpdateContact(availabilityMessage: availabilityMessage)
    }

    private mutating func advanceDeleteContact(
        _ message: String,
        snapshot: CRMDataSnapshot,
        availabilityMessage: String
    ) -> Response {
        guard !snapshot.contacts.isEmpty else {
            return Response(
                workflow: nil,
                    result: Self.reply(
                    "There are no contacts to delete yet.",
                    detail: "Your local CRM is empty, so I will not invent a contact to delete.",
                    availabilityMessage: availabilityMessage
                )
            )
        }

        let matches = matchingContacts(for: message, in: snapshot)
        if matches.count == 1 {
            return proposeDeleteContact(matches[0], availabilityMessage: availabilityMessage)
        }
        if matches.count > 1 {
            return chooseContact(
                "Which contact should I delete?",
                matches: matches,
                availabilityMessage: availabilityMessage
            )
        }
        return chooseContact(
            "Which contact should I delete?",
            matches: Array(snapshot.contacts.prefix(4)),
            availabilityMessage: availabilityMessage
        )
    }

    private mutating func advanceCompleteFollowUp(
        _ message: String,
        snapshot: CRMDataSnapshot,
        availabilityMessage: String
    ) -> Response {
        let openFollowUps = snapshot.followUps.filter { $0.state == FollowUpState.open.rawValue }
        guard !openFollowUps.isEmpty else {
            return Response(
                workflow: nil,
                    result: Self.reply(
                    "There are no open follow-ups to complete.",
                    detail: "I only mark real open local follow-ups as done.",
                    availabilityMessage: availabilityMessage
                )
            )
        }

        let matches = matchingFollowUps(for: message, in: openFollowUps, snapshot: snapshot)
        if matches.count == 1 {
            return proposeCompleteFollowUp(matches[0], snapshot: snapshot, availabilityMessage: availabilityMessage)
        }
        return ask(
            "Which follow-up should I mark as done?",
            options: optionTitles(for: matches.isEmpty ? Array(openFollowUps.prefix(4)) : matches, snapshot: snapshot),
            placeholder: "Follow-up title",
            availabilityMessage: availabilityMessage
        )
    }

    private mutating func mergeContactFields(from message: String) {
        guard let text = message.nilIfBlank else { return }
        let hadContactName = slots.contactName?.nilIfBlank != nil
        let parsed = Self.parseContactAndCompany(from: text)
        if slots.contactName == nil {
            slots.contactName = parsed.name
        }
        if slots.company == nil {
            slots.company = parsed.company ?? (hadContactName ? Self.trimNoise(text).nilIfBlank : nil)
        }
        if slots.email == nil {
            slots.email = Self.firstEmail(in: text)
        }
        if slots.phone == nil {
            slots.phone = Self.firstPhone(in: text)
        }
    }

    private mutating func mergeUpdateFields(from message: String) {
        let key = message.searchKey
        if let email = Self.firstEmail(in: message) {
            slots.email = email
        }
        if let phone = Self.firstPhone(in: message) {
            slots.phone = phone
        }
        if key.contains("company") || key.contains("firma") {
            slots.company = Self.valueAfterMarker(in: message, markers: ["company", "firma", "at", "bei"])
        }
        if key.contains("role") || key.contains("position") || key.contains("title") || key.contains("rolle") {
            slots.role = Self.valueAfterMarker(in: message, markers: ["role", "position", "title", "rolle"])
        }
        if slots.email == nil, slots.phone == nil, slots.company == nil, slots.role == nil {
            slots.notes = message.nilIfBlank
        }
    }

    private var hasUpdateFields: Bool {
        slots.company?.nilIfBlank != nil ||
            slots.role?.nilIfBlank != nil ||
            slots.email?.nilIfBlank != nil ||
            slots.phone?.nilIfBlank != nil ||
            slots.notes?.nilIfBlank != nil
    }

    private func proposeCreateContact(
        contactName: String,
        company: String,
        availabilityMessage: String
    ) -> Response {
        var changes = [
            ProposedChange(
                action: .createContact,
                title: "Create contact \(contactName)",
                contactName: contactName,
                company: company,
                role: slots.role,
                email: slots.email,
                phone: slots.phone,
                tags: slots.directCreateContact ? [] : ["lead"]
            )
        ]

        if slots.wantsFollowUp == true, let followUpTitle = slots.followUpTitle?.nilIfBlank {
            changes.append(ProposedChange(
                action: .createFollowUp,
                title: "Create follow-up",
                contactName: contactName,
                company: company,
                followUpTitle: followUpTitle,
                dueDateText: slots.dueDateText?.nilIfBlank,
                tags: slots.directCreateContact ? [] : ["lead"]
            ))
        }

        return propose(
            "I prepared a review draft for \(contactName).",
            facts: [
                DetectedFact(kind: .contact, value: contactName, detail: "Provided in chat"),
                DetectedFact(kind: .company, value: company, detail: "Provided in chat")
            ],
            changes: changes,
            availabilityMessage: availabilityMessage
        )
    }

    private func proposeCreateFollowUp(availabilityMessage: String) -> Response {
        guard let contact = slots.targetContact,
              let followUpTitle = slots.followUpTitle?.nilIfBlank else {
            return ask(
                "Who is the follow-up for?",
                placeholder: "Contact name",
                availabilityMessage: availabilityMessage
            )
        }

        return propose(
            "I prepared a follow-up for \(contact.fullName).",
            facts: [
                DetectedFact(kind: .contact, value: contact.fullName, detail: "Matched existing local contact"),
                DetectedFact(kind: .followUp, value: followUpTitle, detail: "Provided in chat")
            ],
            changes: [
                ProposedChange(
                    action: .createFollowUp,
                    title: "Create follow-up",
                    targetID: contact.id,
                    contactName: contact.fullName,
                    company: contact.company,
                    followUpTitle: followUpTitle,
                    dueDateText: slots.dueDateText?.nilIfBlank
                )
            ],
            availabilityMessage: availabilityMessage
        )
    }

    private func proposeUpdateContact(availabilityMessage: String) -> Response {
        guard let contact = slots.targetContact else {
            return ask("Which contact should I update?", availabilityMessage: availabilityMessage)
        }

        return propose(
            "I prepared an update for \(contact.fullName).",
            facts: [
                DetectedFact(kind: .contact, value: contact.fullName, detail: "Matched existing local contact")
            ],
            changes: [
                ProposedChange(
                    action: .updateContact,
                    title: "Update \(contact.fullName)",
                    targetID: contact.id,
                    contactName: contact.fullName,
                    company: slots.company,
                    role: slots.role,
                    email: slots.email,
                    phone: slots.phone,
                    notes: slots.notes
                )
            ],
            availabilityMessage: availabilityMessage
        )
    }

    private func proposeDeleteContact(_ contact: CRMContactSnapshot, availabilityMessage: String) -> Response {
        propose(
            "I found one matching contact. Review the delete card before saving.",
            facts: [
                DetectedFact(kind: .contact, value: contact.fullName, detail: "Matched existing local contact")
            ],
            changes: [
                ProposedChange(
                    action: .deleteContact,
                    title: "Delete \(contact.fullName)",
                    targetID: contact.id,
                    contactName: contact.fullName,
                    company: contact.company
                )
            ],
            availabilityMessage: availabilityMessage
        )
    }

    private func proposeCompleteFollowUp(
        _ followUp: CRMFollowUpSnapshot,
        snapshot: CRMDataSnapshot,
        availabilityMessage: String
    ) -> Response {
        let contact = followUp.contactID.flatMap { id in snapshot.contacts.first { $0.id == id } }
        return propose(
            "I prepared this follow-up to be marked done.",
            facts: [
                DetectedFact(kind: .followUp, value: followUp.title, detail: "Matched existing open follow-up")
            ],
            changes: [
                ProposedChange(
                    action: .completeFollowUp,
                    title: "Complete \(followUp.title)",
                    targetID: followUp.id,
                    contactName: contact?.fullName,
                    company: contact?.company,
                    followUpTitle: followUp.title,
                    followUpState: FollowUpState.done.rawValue
                )
            ],
            availabilityMessage: availabilityMessage
        )
    }

    private func ask(
        _ question: String,
        options: [String] = [],
        placeholder: String? = nil,
        availabilityMessage: String
    ) -> Response {
        Response(
            workflow: self,
            result: AgentRunResult(
                kind: .clarify,
                message: question,
                thought: "",
                draft: AgentDraft(
                    summary: "",
                    detectedFacts: [],
                    proposedChanges: [],
                    clarification: ClarificationPrompt(
                        question: question,
                        options: options,
                        allowsFreeText: true,
                        placeholder: placeholder
                    ),
                    spokenConfirmation: ""
                ),
                timeline: [],
                availabilityMessage: availabilityMessage,
                errorMessage: nil
            )
        )
    }

    private func chooseContact(
        _ question: String,
        matches: [CRMContactSnapshot],
        availabilityMessage: String
    ) -> Response {
        ask(
            question,
            options: matches.map { contactOption($0) },
            placeholder: "Contact name",
            availabilityMessage: availabilityMessage
        )
    }

    private func propose(
        _ message: String,
        facts: [DetectedFact],
        changes: [ProposedChange],
        availabilityMessage: String
    ) -> Response {
        Response(
            workflow: nil,
            result: AgentRunResult(
                kind: .propose,
                message: message,
                thought: "",
                draft: AgentDraft(
                    summary: message,
                    detectedFacts: facts,
                    proposedChanges: changes,
                    clarification: nil,
                    spokenConfirmation: "Done. I saved the CRM updates locally."
                ),
                timeline: [
                    AgentTimelineItem(title: "Guided workflow", detail: "Prepared from explicit chat answers without model tool calls.", systemImage: "checkmark.seal")
                ],
                availabilityMessage: availabilityMessage,
                errorMessage: nil
            )
        )
    }

    private static func reply(
        _ title: String,
        detail: String,
        availabilityMessage: String
    ) -> AgentRunResult {
        AgentRunResult(
            kind: .reply,
            message: [title, detail].joined(separator: " "),
            thought: "",
            draft: .empty,
            timeline: [],
            availabilityMessage: availabilityMessage,
            errorMessage: nil
        )
    }
}

private extension AgentGuidedWorkflow {
    static func isCreateContactIntent(_ key: String) -> Bool {
        key.contains("new lead") ||
            key.contains("neuer lead") ||
            key.contains("neuen lead") ||
            key.contains("new contact") ||
            key.contains("create contact") ||
            key.contains("add contact") ||
            key.contains("kontakt anlegen") ||
            key.contains("kontakt erstellen") ||
            key.contains("kontakt hinzufug")
    }

    static func isDeleteContactIntent(_ key: String) -> Bool {
        (key.contains("delete") || key.contains("remove") || key.contains("losch")) &&
            (key.contains("contact") || key.contains("kontakt")) &&
            !key.contains("follow") &&
            !key.contains("opportunity")
    }

    static func isCreateFollowUpIntent(_ key: String) -> Bool {
        (key.contains("create") || key.contains("add") || key.contains("new") || key.contains("erstell") || key.contains("anleg")) &&
            (key.contains("follow") || key.contains("task") || key.contains("nachfass") || key.contains("aufgabe") || key.contains("erinner"))
    }

    static func isCompleteFollowUpIntent(_ key: String) -> Bool {
        (key.contains("complete") || key.contains("done") || key.contains("erledigt") || key.contains("mark")) &&
            (key.contains("follow") || key.contains("task") || key.contains("nachfass") || key.contains("aufgabe"))
    }

    static func isUpdateContactIntent(_ key: String) -> Bool {
        (key.contains("update") || key.contains("change") || key.contains("edit") || key.contains("ander") || key.contains("korrigier")) &&
            (key.contains("contact") || key.contains("kontakt"))
    }

    static func wantsExistingData(_ key: String) -> Bool {
        key.contains("delete") ||
            key.contains("remove") ||
            key.contains("losch") ||
            key.contains("update") ||
            key.contains("complete") ||
            key.contains("done") ||
            key.contains("erledigt") ||
            key.contains("due") ||
            key.contains("pipeline")
    }

    static func cleanRecordQuery(_ text: String) -> String {
        clean(text, removing: [
            "delete", "remove", "contact", "kontakt", "losche", "loesche", "loschen",
            "complete", "done", "mark", "follow-up", "follow up", "followup", "task",
            "erledigt", "aufgabe", "nachfassen", "nachfass", "update", "change", "edit",
            "andere", "aendere", "ander", "korrigiere"
        ])
    }

    static func cleanFollowUpTitle(_ text: String) -> String {
        clean(text, removing: [
            "create", "add", "new", "follow-up", "follow up", "followup", "task",
            "for", "fur", "fuer", "create follow-up", "add a follow-up",
            "erstell", "anleg", "aufgabe", "nachfassen", "nachfass"
        ])
    }

    static func clean(_ text: String, removing markers: [String]) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in markers {
            value = value.replacingOccurrences(of: marker, with: "", options: [.caseInsensitive, .diacriticInsensitive])
        }
        return trimNoise(value)
    }

    static func trimNoise(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;-_!?()[]{}\"'\n\t"))
    }

    static func parseContactAndCompany(from text: String) -> (name: String?, company: String?) {
        for separator in [" at ", " bei ", " from ", " von ", " @ "] {
            if let range = text.range(of: separator, options: [.caseInsensitive, .diacriticInsensitive]) {
                let left = String(text[..<range.lowerBound])
                let right = String(text[range.upperBound...])
                return (
                    sanitizedContactName(from: clean(left, removing: contactCommandMarkers)),
                    trimNoise(right).nilIfBlank
                )
            }
        }

        let cleaned = clean(text, removing: contactCommandMarkers)
        return (sanitizedContactName(from: cleaned), nil)
    }

    static var contactCommandMarkers: [String] {
        [
            "i have a new contact",
            "i have a new lead",
            "create a new contact",
            "create new contact",
            "add a new contact",
            "add new contact",
            "create contact",
            "add contact",
            "new contact",
            "new lead",
            "ich habe einen neuen kontakt",
            "ich habe einen neuen lead",
            "kontakt anlegen",
            "kontakt erstellen",
            "kontakt hinzufugen",
            "kontakt hinzufuegen",
            "neuen kontakt",
            "neuer kontakt",
            "neuen lead",
            "neuer lead",
            "contact",
            "kontakt",
            "lead",
            "i have a",
            "ich habe einen",
            "ich habe ein"
        ]
    }

    static func sanitizedContactName(from text: String) -> String? {
        guard let value = trimNoise(text).nilIfBlank else { return nil }
        let key = value.searchKey
        let commandOnlyKeys: Set<String> = [
            "create",
            "add",
            "new",
            "contact",
            "lead",
            "kontakt",
            "anlegen",
            "erstellen",
            "hinzufugen",
            "hinzufuegen"
        ]

        let words = key.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        guard !words.allSatisfy({ commandOnlyKeys.contains($0) }) else { return nil }
        return value
    }

    static func firstEmail(in text: String) -> String? {
        text.split(separator: " ").map(String.init).first { $0.contains("@") && $0.contains(".") }?.trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
    }

    static func firstPhone(in text: String) -> String? {
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-/")
        let candidates = text.split(separator: " ").map(String.init).filter { value in
            value.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
        let joined = candidates.joined(separator: " ").nilIfBlank
        guard let joined, joined.filter(\.isNumber).count >= 6 else { return nil }
        return joined
    }

    static func valueAfterMarker(in text: String, markers: [String]) -> String? {
        for marker in markers {
            if let range = text.range(of: marker, options: [.caseInsensitive, .diacriticInsensitive]) {
                return trimNoise(String(text[range.upperBound...])).nilIfBlank
            }
        }
        return nil
    }

    static func inferDueDateText(from text: String) -> String? {
        let key = text.searchKey
        if key.contains("today") || key.contains("heute") {
            return "today"
        }
        if key.contains("tomorrow") || key.contains("morgen") {
            return "tomorrow"
        }
        if key.contains("next week") || key.contains("nachste woche") {
            return "next week"
        }
        return nil
    }

    func matchingContacts(for query: String, in snapshot: CRMDataSnapshot) -> [CRMContactSnapshot] {
        let key = query.searchKey
        guard !key.isEmpty else { return [] }
        return snapshot.contacts.filter { contact in
            contact.fullName.searchKey.contains(key) ||
                key.contains(contact.fullName.searchKey) ||
                contact.company.searchKey.contains(key) ||
                (!contact.company.searchKey.isEmpty && key.contains(contact.company.searchKey))
        }
    }

    func matchingFollowUps(
        for query: String,
        in followUps: [CRMFollowUpSnapshot],
        snapshot: CRMDataSnapshot
    ) -> [CRMFollowUpSnapshot] {
        let key = query.searchKey
        guard !key.isEmpty else { return [] }
        return followUps.filter { followUp in
            let contact = followUp.contactID.flatMap { id in snapshot.contacts.first { $0.id == id } }
            return followUp.title.searchKey.contains(key) ||
                key.contains(followUp.title.searchKey) ||
                followUp.notes.searchKey.contains(key) ||
                contact?.fullName.searchKey.contains(key) == true ||
                key.contains(contact?.fullName.searchKey ?? " ")
        }
    }

    func contactOption(_ contact: CRMContactSnapshot) -> String {
        if let company = contact.company.nilIfBlank {
            return "\(contact.fullName) at \(company)"
        }
        return contact.fullName
    }

    func optionTitles(
        for followUps: [CRMFollowUpSnapshot],
        snapshot: CRMDataSnapshot
    ) -> [String] {
        followUps.map { followUp in
            let contact = followUp.contactID.flatMap { id in snapshot.contacts.first { $0.id == id } }
            if let contact {
                return "\(followUp.title) for \(contact.fullName)"
            }
            return followUp.title
        }
    }
}

private extension CRMDataSnapshot {
    var isEmpty: Bool {
        contacts.isEmpty && opportunities.isEmpty && followUps.isEmpty
    }
}
