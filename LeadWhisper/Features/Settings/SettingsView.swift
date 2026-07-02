import FactoryKit
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @InjectedObject(\.crmRepository) private var crmRepository
    @Query private var contacts: [Contact]
    @Query private var opportunities: [Opportunity]
    @Query private var followUps: [FollowUpTask]
    @Query private var interactions: [Interaction]
    @Query private var activityEvents: [ActivityEvent]
    @AppStorage(AgentSettings.debugModeKey) private var isAgentDebugModeEnabled = false
    @State private var isConfirmingDeleteAllData = false
    @State private var statusMessage: String?
    @State private var actionError: PresentableError?

    private var totalRecords: Int {
        contacts.count + opportunities.count + followUps.count + interactions.count + activityEvents.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Data") {
                    LabeledContent("Contacts", value: contacts.count.formatted())
                    LabeledContent("Opportunities", value: opportunities.count.formatted())
                    LabeledContent("Follow-ups", value: followUps.count.formatted())
                    LabeledContent("Interactions", value: interactions.count.formatted())
                    LabeledContent("Activity entries", value: activityEvents.count.formatted())
                }

                Section {
                    Toggle(isOn: $isAgentDebugModeEnabled) {
                        Label("Show Agent Reasoning", systemImage: "brain")
                    }
                } header: {
                    Text("Agent")
                } footer: {
                    Text("Always expands the agent's ReAct trace - thought, tool actions, and observations - on every result card.")
                }

                Section("Demo") {
                    Button {
                        loadDemoData()
                    } label: {
                        Label("Load Demo Data", systemImage: "tray.and.arrow.down")
                    }
                }

                Section("Danger Zone") {
                    Button(role: .destructive) {
                        isConfirmingDeleteAllData = true
                    } label: {
                        Label("Delete All Data", systemImage: "trash")
                    }
                    .disabled(totalRecords == 0)
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Delete all data?",
                isPresented: $isConfirmingDeleteAllData,
                titleVisibility: .visible
            ) {
                Button("Delete All Data", role: .destructive) {
                    deleteAllData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes contacts, opportunities, follow-ups, interactions, and activity history.")
            }
            .crmErrorAlert($actionError)
        }
    }

    private func loadDemoData() {
        do {
            try DemoDataSeeder.seed(in: modelContext)
            statusMessage = "Demo data loaded."
        } catch {
            actionError = PresentableError(error)
        }
    }

    private func deleteAllData() {
        do {
            try crmRepository.deleteAllData()
            statusMessage = "All data deleted."
        } catch {
            actionError = PresentableError(error)
        }
    }
}
