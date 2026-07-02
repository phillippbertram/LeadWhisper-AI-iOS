import SwiftUI

struct AgentResultView: View {
    let runResult: AgentRunResult
    let save: () -> Void
    let cancel: () -> Void
    let answerClarification: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if runResult.usedMockParser {
                Label("Demo parser fallback", systemImage: "switch.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AgentTimelineView(items: runResult.timeline)
            DetectedFactsView(facts: runResult.draft.detectedFacts)

            if let clarification = runResult.draft.clarification {
                ClarificationView(clarification: clarification, select: answerClarification)

                Button(role: .cancel, action: cancel) {
                    Label("Cancel Draft", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                ProposedChangesView(changes: runResult.draft.proposedChanges)

                HStack(spacing: 12) {
                    Button(role: .cancel, action: cancel) {
                        Label("Cancel", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: save) {
                        Label("Save Changes", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!runResult.draft.canApply)
                }
            }
        }
    }
}

private struct AgentTimelineView: View {
    let items: [AgentTimelineItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent Plan")
                .font(.headline)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.systemImage)
                        .foregroundStyle(.blue)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                        Text(item.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DetectedFactsView: View {
    let facts: [DetectedFact]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Detected Facts")
                .font(.headline)
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: fact.kind))
                        .foregroundStyle(.green)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.value)
                            .font(.subheadline.weight(.semibold))
                        Text(fact.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "contact":
            "person"
        case "company":
            "building.2"
        case "opportunity":
            "chart.line.uptrend.xyaxis"
        case "budget":
            "eurosign.circle"
        case "stage":
            "flag"
        case "followUp":
            "bell"
        default:
            "note.text"
        }
    }
}

private struct ProposedChangesView: View {
    let changes: [ProposedChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Proposed Changes")
                .font(.headline)
            ForEach(changes) { change in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(change.title, systemImage: icon(for: change.action))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(change.action)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        if let contactName = change.contactName?.nilIfBlank {
                            LabeledContent("Contact", value: contactName)
                        }
                        if let company = change.company?.nilIfBlank {
                            LabeledContent("Company", value: company)
                        }
                        if let opportunityTitle = change.opportunityTitle?.nilIfBlank {
                            LabeledContent("Opportunity", value: opportunityTitle)
                        }
                        if let stage = change.stage.flatMap(OpportunityStage.from) {
                            LabeledContent("Stage", value: stage.title)
                        }
                        if let value = change.estimatedValueEUR {
                            LabeledContent("Value", value: value.formatted(.currency(code: "EUR").precision(.fractionLength(0))))
                        } else if let budget = change.budgetText?.nilIfBlank {
                            LabeledContent("Budget", value: budget)
                        }
                        if let dueDate = change.dueDateText?.nilIfBlank {
                            LabeledContent("Due", value: dueDate)
                        }
                        if let notes = change.notes?.nilIfBlank {
                            Text(notes)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        TagStrip(tags: change.tags)
                    }
                    .font(.footnote)
                }
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary)
                }
            }
        }
    }

    private func icon(for action: String) -> String {
        switch action {
        case "createContact", "updateContact":
            "person.crop.circle.badge.plus"
        case "createOpportunity", "updateOpportunityStage":
            "chart.line.uptrend.xyaxis"
        case "createFollowUp", "updateFollowUp", "archiveFollowUps":
            "bell"
        default:
            "text.bubble"
        }
    }
}

private struct ClarificationView: View {
    let clarification: ClarificationPrompt
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Clarification Needed", systemImage: "questionmark.circle")
                .font(.headline)
            Text(clarification.question)
                .font(.body)
            ForEach(clarification.options, id: \.self) { option in
                Button {
                    select(option)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.title3)
                        Text(option)
                            .font(.headline)
                            .lineLimit(2)
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
