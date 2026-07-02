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
    @AppStorage(AgentSettings.providerKindKey) private var selectedProviderRawValue = AgentProviderKind.appleFoundationModels.rawValue
    @State private var openAIAPIKey = ""
    @State private var hasOpenAIAPIKey = false
    @State private var isConfirmingDeleteAllData = false
    @State private var statusMessage: String?
    @State private var actionError: PresentableError?

    private var totalRecords: Int {
        contacts.count + opportunities.count + followUps.count + interactions.count + activityEvents.count
    }

    private var selectedProviderKind: AgentProviderKind {
        AgentProviderKind(rawValue: selectedProviderRawValue) ?? .appleFoundationModels
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
                    Picker("Model Provider", selection: $selectedProviderRawValue) {
                        ForEach(AgentProviderKind.allCases) { provider in
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                    }

                    LabeledContent("Model", value: selectedProviderKind.modelDisplayName)

                    Toggle(isOn: $isAgentDebugModeEnabled) {
                        Label("Show Agent Reasoning", systemImage: "brain")
                    }
                } header: {
                    Text("Agent")
                } footer: {
                    Text("Choose the provider and model used for agent turns. OpenAI sends submitted agent messages and local lookup results to OpenAI. Debug mode expands the ReAct trace on every result card.")
                }

                Section {
                    if hasOpenAIAPIKey {
                        Label("API key saved", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                    }

                    SecureField("OpenAI API key", text: $openAIAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        saveOpenAIAPIKey()
                    } label: {
                        Label(hasOpenAIAPIKey ? "Replace API Key" : "Save API Key", systemImage: "key")
                    }
                    .disabled(openAIAPIKey.nilIfBlank == nil)

                    if hasOpenAIAPIKey {
                        Button(role: .destructive) {
                            deleteOpenAIAPIKey()
                        } label: {
                            Label("Delete API Key", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("OpenAI")
                } footer: {
                    Text("The key is stored in Keychain on this device. When OpenAI is selected, agent messages and local CRM lookup results are sent to OpenAI to draft reviewable changes.")
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
            .onAppear {
                refreshOpenAIKeyStatus()
            }
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

    private func refreshOpenAIKeyStatus() {
        hasOpenAIAPIKey = Container.shared.agentCredentialStore().hasOpenAIAPIKey()
    }

    private func saveOpenAIAPIKey() {
        do {
            try Container.shared.agentCredentialStore().saveOpenAIAPIKey(openAIAPIKey)
            openAIAPIKey = ""
            hasOpenAIAPIKey = true
            statusMessage = "OpenAI API key saved."
        } catch {
            actionError = PresentableError(error)
        }
    }

    private func deleteOpenAIAPIKey() {
        do {
            try Container.shared.agentCredentialStore().deleteOpenAIAPIKey()
            openAIAPIKey = ""
            hasOpenAIAPIKey = false
            statusMessage = "OpenAI API key deleted."
        } catch {
            actionError = PresentableError(error)
        }
    }
}
