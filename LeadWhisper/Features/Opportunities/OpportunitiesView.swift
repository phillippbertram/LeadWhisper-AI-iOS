import FactoryKit
import SwiftData
import SwiftUI

struct OpportunitiesView: View {
    @InjectedObject(\.crmRepository) private var crmRepository
    @Query(sort: [SortDescriptor(\Opportunity.updatedAt, order: .reverse)])
    private var opportunities: [Opportunity]
    @State private var sheet: OpportunitiesSheet?
    @State private var pendingDeleteOpportunity: Opportunity?
    @State private var actionError: PresentableError?

    // Grouped once per update; the store-level sort keeps each group ordered.
    private var opportunitiesByStage: [OpportunityStage: [Opportunity]] {
        Dictionary(grouping: opportunities, by: \.stage)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Opportunities")
                .talkFloatingAction {
                    sheet = .agent(initialPrompt: nil)
                }
                .sheet(item: $sheet) { sheet in
                    switch sheet {
                    case .agent(let initialPrompt):
                        AgentComposerSheetView(initialPrompt: initialPrompt)
                    case .editOpportunity(let opportunity):
                        OpportunityEditView(opportunity: opportunity)
                    }
                }
                .confirmationDialog(
                    "Delete opportunity?",
                    isPresented: .init(isPresenting: $pendingDeleteOpportunity),
                    titleVisibility: .visible,
                    presenting: pendingDeleteOpportunity
                ) { opportunity in
                    Button("Delete Opportunity", role: .destructive) {
                        if perform({ try $0.deleteOpportunity(opportunity) }) {
                            HapticFeedback.play(.success)
                        }
                        pendingDeleteOpportunity = nil
                    }
                    Button("Cancel", role: .cancel) {
                        pendingDeleteOpportunity = nil
                    }
                } message: { _ in
                    Text("Linked follow-ups are deleted. Interactions keep their history but are unlinked.")
                }
                .crmErrorAlert($actionError)
        }
    }

    @ViewBuilder
    private var content: some View {
        if opportunities.isEmpty {
            ContentUnavailableView {
                Label("No opportunities yet", systemImage: "chart.line.uptrend.xyaxis")
            } description: {
                Text("Capture a lead update to start building your local pipeline.")
            } actions: {
                Button {
                    HapticFeedback.play(.lightImpact)
                    sheet = .agent(initialPrompt: nil)
                } label: {
                    Label("Type Update", systemImage: "keyboard")
                }
            }
        } else {
            opportunityList
        }
    }

    private var opportunityList: some View {
        List {
            ForEach(OpportunityStage.allCases) { stage in
                if let stageOpportunities = opportunitiesByStage[stage] {
                    Section(stage.title) {
                        ForEach(stageOpportunities) { opportunity in
                            OpportunityRow(opportunity: opportunity)
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    Button {
                                        HapticFeedback.play(.lightImpact)
                                        sheet = .agent(initialPrompt: agentPrompt(for: opportunity))
                                    } label: {
                                        Label("Agent", systemImage: "sparkles")
                                    }
                                    .tint(.blue)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        HapticFeedback.play(.warning)
                                        pendingDeleteOpportunity = opportunity
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(.red)

                                    Button {
                                        sheet = .editOpportunity(opportunity)
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
    }

    @discardableResult
    private func perform(_ action: (CRMRepository) throws -> Void) -> Bool {
        do {
            try action(crmRepository)
            return true
        } catch {
            actionError = PresentableError(error)
            return false
        }
    }

    private func agentPrompt(for opportunity: Opportunity) -> String {
        if opportunity.company.isEmpty {
            return "Update the opportunity \(opportunity.title)"
        }
        return "Update the opportunity \(opportunity.title) at \(opportunity.company)"
    }
}

private enum OpportunitiesSheet: Identifiable {
    case agent(initialPrompt: String?)
    case editOpportunity(Opportunity)

    var id: String {
        switch self {
        case .agent(let initialPrompt):
            "agent-\(initialPrompt ?? "blank")"
        case .editOpportunity(let opportunity):
            "editOpportunity-\(opportunity.id.uuidString)"
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

    private var nextFollowUp: FollowUpTask? {
        opportunity.followUps
            .filter { $0.state == .open }
            .sorted(by: FollowUpTask.dueDateOrder)
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
