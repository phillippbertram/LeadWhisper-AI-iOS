import SwiftData
import SwiftUI

struct OpportunitiesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var opportunities: [Opportunity]
    @Query private var followUps: [FollowUpTask]
    @State private var sheet: OpportunitiesSheet?
    @State private var pendingDeleteOpportunity: Opportunity?

    var body: some View {
        NavigationStack {
            List {
                ForEach(OpportunityStage.allCases) { stage in
                    let stageOpportunities = opportunities
                        .filter { $0.stage == stage }
                        .sorted { $0.updatedAt > $1.updatedAt }

                    if !stageOpportunities.isEmpty {
                        Section(stage.title) {
                            ForEach(stageOpportunities) { opportunity in
                                OpportunityRow(opportunity: opportunity, followUps: followUps)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            pendingDeleteOpportunity = opportunity
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }

                                        Button {
                                            sheet = .editOpportunity(opportunity.id)
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        .tint(.blue)
                                    }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Opportunities")
            .talkFloatingAction {
                sheet = .agent
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .agent:
                    AgentComposerSheetView()
                case .editOpportunity(let id):
                    if let opportunity = opportunities.first(where: { $0.id == id }) {
                        OpportunityEditView(opportunity: opportunity)
                    }
                }
            }
            .confirmationDialog(
                "Delete opportunity?",
                isPresented: Binding(
                    get: { pendingDeleteOpportunity != nil },
                    set: { if !$0 { pendingDeleteOpportunity = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Opportunity", role: .destructive) {
                    if let pendingDeleteOpportunity {
                        try? CRMRepository(context: modelContext).deleteOpportunity(pendingDeleteOpportunity)
                    }
                    pendingDeleteOpportunity = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteOpportunity = nil
                }
            } message: {
                Text("Linked follow-ups are deleted. Interactions keep their history but are unlinked.")
            }
        }
    }
}

private enum OpportunitiesSheet: Identifiable {
    case agent
    case editOpportunity(UUID)

    var id: String {
        switch self {
        case .agent:
            "agent"
        case .editOpportunity(let id):
            "editOpportunity-\(id.uuidString)"
        }
    }
}

struct OpportunitySummaryRow: View {
    let opportunity: Opportunity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(opportunity.title)
                    .font(.headline)
                Spacer()
                StageBadge(stage: opportunity.stage)
            }
            if !opportunity.company.isEmpty {
                Text(opportunity.company)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            OpportunityMetaLine(opportunity: opportunity)
            TagStrip(tags: opportunity.tags)
        }
        .padding(.vertical, 5)
    }
}

private struct OpportunityRow: View {
    let opportunity: Opportunity
    let followUps: [FollowUpTask]

    private var nextFollowUp: FollowUpTask? {
        followUps
            .filter { $0.opportunityID == opportunity.id && $0.state == .open }
            .sorted { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
                case let (left?, right?):
                    left < right
                case (_?, nil):
                    true
                case (nil, _?):
                    false
                case (nil, nil):
                    lhs.createdAt < rhs.createdAt
                }
            }
            .first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            OpportunitySummaryRow(opportunity: opportunity)

            if let nextFollowUp {
                Label(nextFollowUp.title, systemImage: "bell")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct OpportunityMetaLine: View {
    let opportunity: Opportunity

    var body: some View {
        HStack(spacing: 10) {
            if let value = opportunity.estimatedValueEUR {
                Label(value.formatted(.currency(code: "EUR").precision(.fractionLength(0))), systemImage: "eurosign.circle")
            } else if !opportunity.budgetText.isEmpty {
                Label(opportunity.budgetText, systemImage: "eurosign.circle")
            }

            if !opportunity.expectedStart.isEmpty {
                Label(opportunity.expectedStart, systemImage: "calendar.badge.clock")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
