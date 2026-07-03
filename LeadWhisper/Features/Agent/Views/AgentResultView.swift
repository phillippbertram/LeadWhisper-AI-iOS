import SwiftUI

struct AgentResultView: View {
    let runResult: AgentRunResult
    var showsActions = true
    let save: ([ProposedChange], Set<String>) -> Void
    let cancel: () -> Void

    @AppStorage(AgentSettings.debugModeKey) private var isDebugModeEnabled = false
    @State private var showsDetails = false
    @State private var deselectedChangeIDs: Set<String> = []
    @State private var editableChanges: [ProposedChange]

    init(
        runResult: AgentRunResult,
        showsActions: Bool = true,
        save: @escaping ([ProposedChange], Set<String>) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.runResult = runResult
        self.showsActions = showsActions
        self.save = save
        self.cancel = cancel
        _editableChanges = State(initialValue: runResult.draft.proposedChanges)
    }

    private var selectedChangeIDs: Set<String> {
        Set(editableChanges.map(\.id)).subtracting(deselectedChangeIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isDebugModeEnabled {
                Text(runResult.kind.rawValue.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.blue.opacity(0.12), in: Capsule())
            }

            if let errorMessage = runResult.errorMessage?.nilIfBlank {
                AgentNoticeView(
                    title: runResult.message.nilIfBlank ?? "Could not draft changes",
                    detail: errorMessage,
                    systemImage: "exclamationmark.triangle",
                    tint: .orange
                )
            } else if let message = runResult.message.nilIfBlank,
                      runResult.draft.clarification == nil {
                Text(message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let clarification = runResult.draft.clarification {
                ClarificationPromptView(clarification: clarification)
            } else if !editableChanges.isEmpty {
                ProposedChangesView(
                    changes: $editableChanges,
                    diffs: runResult.diffs,
                    selectedCount: selectedChangeIDs.count,
                    isSelectable: showsActions,
                    isSelected: { !deselectedChangeIDs.contains($0) },
                    toggleSelection: { id in
                        if deselectedChangeIDs.contains(id) {
                            deselectedChangeIDs.remove(id)
                        } else {
                            deselectedChangeIDs.insert(id)
                        }
                    }
                )
                if showsActions && runResult.draft.canApply {
                    reviewActionButtons
                }
            } else if runResult.errorMessage == nil {
                AgentNoticeView(
                    title: "I need a little more context",
                    detail: "Tell me which contact, opportunity, or follow-up you want to change and what should happen next.",
                    systemImage: "questionmark.circle",
                    tint: .blue
                )
            }

            if hasDetails {
                detailsSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasDetails: Bool {
        !runResult.timeline.isEmpty || !runResult.draft.detectedFacts.isEmpty
    }

    @ViewBuilder
    private var detailsSection: some View {
        if !isDebugModeEnabled {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    showsDetails.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(showsDetails ? 90 : 0))
                    Text(showsDetails ? "Hide details" : "Details")
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }

        if showsDetails || isDebugModeEnabled {
            if !runResult.draft.detectedFacts.isEmpty {
                DetectedFactsView(facts: runResult.draft.detectedFacts)
            }
            if !runResult.timeline.isEmpty {
                AgentTimelineView(items: runResult.timeline)
            }
        }
    }

    private var reviewActionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                cancelButton
                saveButton
            }

            VStack(spacing: 10) {
                saveButton
                cancelButton
            }
        }
    }

    private var cancelButton: some View {
        Button(role: .cancel, action: cancel) {
            Label("Cancel", systemImage: "xmark")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    private var saveButton: some View {
        Button {
            save(editableChanges, selectedChangeIDs)
        } label: {
            Label(saveButtonTitle, systemImage: "checkmark")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!runResult.draft.canApply || selectedChangeIDs.isEmpty)
    }

    private var saveButtonTitle: String {
        let total = editableChanges.count
        let selected = selectedChangeIDs.count
        guard total > 1, selected < total else { return "Save Changes" }
        return "Save \(selected) of \(total)"
    }
}

private struct AgentTimelineView: View {
    let items: [AgentTimelineItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reasoning")
                .font(.subheadline.weight(.semibold))
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.systemImage)
                        .foregroundStyle(.blue)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.footnote.weight(.semibold))
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct DetectedFactsView: View {
    let facts: [DetectedFact]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Detected Facts")
                .font(.headline)
            ForEach(facts, id: \.self) { fact in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: fact.kind.systemImage)
                        .foregroundStyle(.green)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.value)
                            .font(.subheadline.weight(.semibold))
                        Text(fact.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProposedChangesView: View {
    @Binding var changes: [ProposedChange]
    let diffs: [String: [ProposedChangeDiffField]]
    let selectedCount: Int
    let isSelectable: Bool
    let isSelected: (String) -> Bool
    let toggleSelection: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReviewSummaryHeader(
                proposedCount: changes.count,
                selectedCount: selectedCount,
                isSelectable: isSelectable
            )
            ForEach($changes) { $change in
                ProposedChangeCard(
                    change: $change,
                    diff: diffs[change.id],
                    isSelectable: isSelectable,
                    isSelected: isSelected(change.id),
                    toggleSelection: { toggleSelection(change.id) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReviewSummaryHeader: View {
    let proposedCount: Int
    let selectedCount: Int
    let isSelectable: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(proposedCount) \(proposedCount == 1 ? "change" : "changes") proposed")
                .font(.headline)
            Spacer(minLength: 8)
            if isSelectable, proposedCount > 1 {
                Text("\(selectedCount) selected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selectedCount == 0 ? .red : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
    }
}

private struct AgentNoticeView: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.18))
        }
    }
}

private struct ProposedChangeCard: View {
    @Binding var change: ProposedChange
    let diff: [ProposedChangeDiffField]?
    let isSelectable: Bool
    let isSelected: Bool
    let toggleSelection: () -> Void
    @State private var isEditing = false

    private var isDestructive: Bool {
        change.action.isDestructive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if isSelectable {
                    Button(action: toggleSelection) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.headline)
                            .foregroundStyle(isSelected ? (isDestructive ? Color.red : .blue) : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelected ? "Exclude \(change.title)" : "Include \(change.title)")
                }
                Label(change.title, systemImage: change.action.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isDestructive ? .red : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(change.action.displayTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isDestructive ? .red : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if !isSelected {
                        Text("Excluded")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }
                if isSelectable, change.action.supportsInlineEdit {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            isEditing.toggle()
                        }
                    } label: {
                        Image(systemName: isEditing ? "checkmark.circle" : "pencil.circle")
                            .font(.headline)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isEditing ? "Finish editing \(change.title)" : "Edit \(change.title)")
                }
            }

            ProposedChangeDetails(change: change, diff: diff)
                .font(.footnote)
                .opacity(isSelected ? 1 : 0.45)

            if isEditing {
                ProposedChangeInlineEditor(change: $change)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isDestructive ? Color.red.opacity(0.08) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isDestructive ? Color.red.opacity(0.28) : Color.secondary.opacity(0.18))
        }
    }
}

private struct ProposedChangeDetails: View {
    let change: ProposedChange
    var diff: [ProposedChangeDiffField]?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let diff, !diff.isEmpty {
                ForEach(diff) { field in
                    ChangeDiffRow(field: field)
                }
                if let notes = change.notes?.nilIfBlank {
                    Text(notes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                TagStrip(tags: change.tags)
            } else {
                standardRows
            }
        }
    }

    @ViewBuilder
    private var standardRows: some View {
        Group {
            if let contactName = change.contactName?.nilIfBlank {
                ChangeDetailRow(title: "Contact", value: contactName)
            }
            if let company = change.company?.nilIfBlank {
                ChangeDetailRow(title: "Company", value: company)
            }
            if let role = change.role?.nilIfBlank {
                ChangeDetailRow(title: "Role", value: role)
            }
            if let email = change.email?.nilIfBlank {
                ChangeDetailRow(title: "Email", value: email)
            }
            if let phone = change.phone?.nilIfBlank {
                ChangeDetailRow(title: "Phone", value: phone)
            }
            if let opportunityTitle = change.opportunityTitle?.nilIfBlank {
                ChangeDetailRow(title: "Opportunity", value: opportunityTitle)
            }
            if let stage = change.stage.flatMap(OpportunityStage.from) {
                ChangeDetailRow(title: "Stage", value: stage.title)
            }
            if let value = change.estimatedValueEUR {
                ChangeDetailRow(title: "Value", value: value.formatted(.currency(code: "EUR").precision(.fractionLength(0))))
            } else if let budget = change.budgetText?.nilIfBlank {
                ChangeDetailRow(title: "Budget", value: budget)
            }
            if let dueDate = change.dueDateText?.nilIfBlank {
                ChangeDetailRow(title: "Due", value: dueDate)
            }
            if let state = change.followUpState?.nilIfBlank {
                ChangeDetailRow(title: "State", value: FollowUpState(rawValue: state)?.title ?? state)
            }
            if let notes = change.notes?.nilIfBlank {
                Text(notes)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            TagStrip(tags: change.tags)
        }
    }
}

private struct ProposedChangeInlineEditor: View {
    @Binding var change: ProposedChange

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if change.action.hasOpportunityFields {
                Picker("Stage", selection: stageBinding) {
                    ForEach(OpportunityStage.allCases) { stage in
                        Text(stage.title).tag(stage)
                    }
                }
                .pickerStyle(.menu)

                TextField("Estimated value EUR", text: estimatedValueBinding)
                    .keyboardType(.numberPad)
                TextField("Budget note", text: textBinding(\.budgetText))
                TextField("Expected start", text: textBinding(\.expectedStart))
            }

            if change.action.hasFollowUpFields {
                TextField("Follow-up title", text: textBinding(\.followUpTitle))
                TextField("Due date", text: textBinding(\.dueDateText))
            }

            TextField("Tags, separated by commas", text: tagsBinding)

            VStack(alignment: .leading, spacing: 5) {
                Text("Notes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: textBinding(\.notes))
                    .frame(minHeight: 76)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .font(.footnote)
        .textFieldStyle(.roundedBorder)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.blue.opacity(0.16))
        }
    }

    private var stageBinding: Binding<OpportunityStage> {
        Binding(
            get: { OpportunityStage.from(change.stage) ?? .lead },
            set: { change.stage = $0.rawValue }
        )
    }

    private var estimatedValueBinding: Binding<String> {
        Binding(
            get: { change.estimatedValueEUR.map(String.init) ?? "" },
            set: { value in
                let digits = value.filter(\.isNumber)
                change.estimatedValueEUR = digits.isEmpty ? nil : Int(digits)
            }
        )
    }

    private var tagsBinding: Binding<String> {
        Binding(
            get: { change.tags.joined(separator: ", ") },
            set: { change.tags = $0.tagsFromCommaSeparatedText() }
        )
    }

    private func textBinding(_ keyPath: WritableKeyPath<ProposedChange, String?>) -> Binding<String> {
        Binding(
            get: { change[keyPath: keyPath] ?? "" },
            set: { change[keyPath: keyPath] = $0.nilIfBlank }
        )
    }
}

private struct ChangeDetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ChangeDiffRow: View {
    let field: ProposedChangeDiffField

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(field.title)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            if let oldValue = field.oldValue {
                VStack(alignment: .leading, spacing: 2) {
                    Text(oldValue)
                        .strikethrough()
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "arrow.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(field.newValue)
                            .fontWeight(.medium)
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(field.newValue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension DetectedFactKind {
    var systemImage: String {
        switch self {
        case .contact:
            "person"
        case .company:
            "building.2"
        case .opportunity:
            "chart.line.uptrend.xyaxis"
        case .budget:
            "eurosign.circle"
        case .stage:
            "flag"
        case .followUp:
            "bell"
        case .tag:
            "tag"
        case .note:
            "note.text"
        case .startDate:
            "calendar"
        }
    }
}

private extension ProposedChangeAction {
    var supportsInlineEdit: Bool {
        !isDestructive
    }

    var hasOpportunityFields: Bool {
        switch self {
        case .createOpportunity, .updateOpportunity, .updateOpportunityStage:
            true
        case .createContact, .updateContact, .createInteraction, .createFollowUp, .updateFollowUp, .completeFollowUp, .archiveFollowUps, .deleteContact, .deleteOpportunity, .deleteFollowUp:
            false
        }
    }

    var hasFollowUpFields: Bool {
        switch self {
        case .createFollowUp, .updateFollowUp:
            true
        case .createContact, .updateContact, .createOpportunity, .updateOpportunity, .updateOpportunityStage, .createInteraction, .completeFollowUp, .archiveFollowUps, .deleteContact, .deleteOpportunity, .deleteFollowUp:
            false
        }
    }

    var displayTitle: String {
        switch self {
        case .createContact:
            "Create contact"
        case .updateContact:
            "Update contact"
        case .createOpportunity:
            "Create opportunity"
        case .updateOpportunity:
            "Update opportunity"
        case .updateOpportunityStage:
            "Move opportunity"
        case .createInteraction:
            "Add activity"
        case .createFollowUp:
            "Create follow-up"
        case .updateFollowUp:
            "Update follow-up"
        case .completeFollowUp:
            "Complete follow-up"
        case .archiveFollowUps:
            "Archive follow-ups"
        case .deleteContact, .deleteOpportunity, .deleteFollowUp:
            "Delete record"
        }
    }

    var systemImage: String {
        switch self {
        case .createContact, .updateContact:
            "person.crop.circle.badge.plus"
        case .createOpportunity, .updateOpportunity, .updateOpportunityStage:
            "chart.line.uptrend.xyaxis"
        case .createFollowUp, .updateFollowUp, .completeFollowUp, .archiveFollowUps:
            "bell"
        case .deleteContact, .deleteOpportunity, .deleteFollowUp:
            "trash"
        case .createInteraction:
            "text.bubble"
        }
    }
}

private struct ClarificationPromptView: View {
    let clarification: ClarificationPrompt

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.bubble")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(clarification.question)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if clarification.allowsFreeText == true {
                    Text(clarification.placeholder?.nilIfBlank ?? "Type your answer below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
