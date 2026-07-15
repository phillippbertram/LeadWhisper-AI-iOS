import Foundation
import FoundationModels
import Observation
import OSLog
import SwiftAgentKit
import SwiftAgentKitFoundationModels
import SwiftAgentKitOpenAI

@MainActor
@Observable
final class AgentActivityRelay {
    private(set) var currentActivity: String?

    func reset() {
        currentActivity = nil
    }

    func hook() -> AnyAgentHook {
        AnyAgentHook { [weak self] event in
            await MainActor.run {
                guard let self else { return }
                switch event {
                case .toolStarted(let name, let arguments):
                    self.currentActivity = arguments == "{}" ? name : "\(name) \(arguments)"
                case .invocationCompleted, .invocationFailed:
                    self.currentActivity = nil
                default:
                    break
                }
            }
        }
    }
}

struct LeadWhisperAgentRuntime {
    var providerKind: AgentProviderKind
    var agent: Agent<AgentTurn>
    var memory: LeadWhisperAgentMemory
    var descriptor: AgentModelDescriptor
    var initialAvailability: AgentModelAvailability
}

@MainActor
final class LeadWhisperAgentFactory {
    private let credentialStore: AgentCredentialStore

    init(credentialStore: AgentCredentialStore) {
        self.credentialStore = credentialStore
    }

    func makeRuntime(
        providerKind: AgentProviderKind,
        dataSource: AgentToolDataSource,
        activityRelay: AgentActivityRelay
    ) -> LeadWhisperAgentRuntime {
        let configuration = ProviderConfiguration(providerKind: providerKind)
        let initialAvailability = initialAvailability(providerKind: providerKind)
        let memory = LeadWhisperAgentMemory(limits: configuration.memoryLimits)
        let model = makeModel(
            providerKind: providerKind,
            unavailableMessage: initialAvailability.unavailableMessage
        )
        let tools = CRMToolCatalog.make(
            dataSource: dataSource,
            outputPolicy: configuration.toolOutputPolicy
        )
        let selector = makeToolSelector(
            providerKind: providerKind,
            model: model,
            memory: memory
        )
        let agent = Agent<AgentTurn>(
            model: model,
            instructions: { toolNames in
                LeadWhisperAgentPrompt.instructions(
                    providerKind: providerKind,
                    toolNames: toolNames
                )
            },
            outputSchema: AgentTurn.outputSchema,
            tools: tools,
            memory: memory,
            toolSelector: selector,
            hooks: [activityRelay.hook()],
            policy: configuration.runtimePolicy
        )

        return LeadWhisperAgentRuntime(
            providerKind: providerKind,
            agent: agent,
            memory: memory,
            descriptor: model.descriptor,
            initialAvailability: initialAvailability
        )
    }

    private func makeModel(
        providerKind: AgentProviderKind,
        unavailableMessage: String
    ) -> any AgentModel {
        switch providerKind {
        case .appleFoundationModels:
            FoundationModelsModel(
                displayName: providerKind.modelDisplayName,
                unavailableMessage: unavailableMessage
            )
        case .openAI:
            OpenAIResponsesModel(
                modelID: "gpt-5.5",
                displayName: providerKind.modelDisplayName,
                contextWindow: 128_000,
                unavailableMessage: unavailableMessage,
                apiKeyProvider: { @MainActor [credentialStore] in
                    try credentialStore.openAIAPIKey()
                }
            )
        }
    }

    private func makeToolSelector(
        providerKind: AgentProviderKind,
        model: any AgentModel,
        memory: LeadWhisperAgentMemory
    ) -> AnyAgentToolSelector {
        guard providerKind == .appleFoundationModels else { return .all }

        return AnyAgentToolSelector { input, tools in
            do {
                let memoryPrompt = await memory.context()
                let schema = AgentToolPlan.outputSchema
                let request = AgentModelRequest(
                    prompt: input,
                    memoryPrompt: memoryPrompt,
                    instructions: LeadWhisperAgentPrompt.toolPlanningInstructions,
                    outputName: schema.name,
                    outputSchema: schema.schema,
                    tools: [],
                    responseTokenLimit: 120,
                    sessionMode: .ephemeral
                )
                let executor = AgentToolExecutor(
                    tools: [],
                    policy: AgentPolicy(maximumToolCalls: 0, responseTokenLimit: 120),
                    hooks: []
                )
                let response = try await model.invoke(request, executor: executor)
                let plan = try schema.decode(response.output)
                let availableNames = Set(tools.map(\.name))
                let selectedNames = plan.toolScope.toolNames.filter(availableNames.contains)
                AppLog.agent.debug("Agent tool plan generated provider=apple scope=\(plan.toolScope.rawValue, privacy: .public)")
                return AgentToolSelection(toolNames: selectedNames, reason: plan.reason)
            } catch {
                AppLog.agent.warning("Agent tool planning failed provider=apple error=\(error.localizedDescription, privacy: .public); using full tools")
                return AgentToolSelection(
                    toolNames: tools.map(\.name),
                    reason: AgentToolPlan.fallback.reason
                )
            }
        }
    }

    private func initialAvailability(providerKind: AgentProviderKind) -> AgentModelAvailability {
        switch providerKind {
        case .appleFoundationModels:
            let model = SystemLanguageModel.default
            let message: String
            switch model.availability {
            case .available:
                message = "Apple Foundation Models available"
            case .unavailable(.appleIntelligenceNotEnabled):
                message = "Apple Intelligence is not enabled."
            case .unavailable(.deviceNotEligible):
                message = "This device is not eligible for Apple Intelligence."
            case .unavailable(.modelNotReady):
                message = "The on-device model is not ready yet."
            @unknown default:
                message = "Foundation Models availability is unknown."
            }
            return AgentModelAvailability(
                isAvailable: model.isAvailable,
                message: message,
                unavailableMessage: "LeadWhisper needs Apple Foundation Models to draft CRM changes. \(message) No local data was changed."
            )

        case .openAI:
            let available = credentialStore.hasOpenAIAPIKey()
            return AgentModelAvailability(
                isAvailable: available,
                message: available ? "OpenAI API key saved." : "OpenAI API key missing.",
                unavailableMessage: "Add an OpenAI API key in Settings to use the OpenAI provider. No local data was changed."
            )
        }
    }
}

private struct ProviderConfiguration {
    var memoryLimits: AgentContextMemoryLimits
    var toolOutputPolicy: AgentToolOutputPolicy
    var runtimePolicy: AgentPolicy

    init(providerKind: AgentProviderKind) {
        switch providerKind {
        case .appleFoundationModels:
            memoryLimits = .appleFoundationModels
            toolOutputPolicy = .appleFoundationModels
            runtimePolicy = AgentPolicy(
                maximumToolCalls: 6,
                responseTokenLimit: 900,
                timeout: .seconds(20)
            )
        case .openAI:
            memoryLimits = .openAI
            toolOutputPolicy = .openAI
            runtimePolicy = AgentPolicy(
                maximumToolCalls: 12,
                responseTokenLimit: 6_000,
                timeout: .seconds(20)
            )
        }
    }
}

enum LeadWhisperAgentPrompt {
    nonisolated static func instructions(providerKind: AgentProviderKind, toolNames: [String]) -> String {
        let scope = AgentToolScope.scope(matching: toolNames)
        switch providerKind {
        case .appleFoundationModels:
            return appleInstructions(scope: scope)
        case .openAI:
            return openAIInstructions(scope: scope)
        }
    }

    nonisolated static let toolPlanningInstructions = """
    You are LeadWhisper's tool planner. Choose the smallest safe tool scope for the next CRM agent turn.
    Return one AgentToolPlan only.
    Scopes:
    - none: no existing CRM lookup is needed; the main agent can draft from user-provided facts or ask a clarification.
    - contacts: the next turn only needs contact search or contact details.
    - opportunities: the next turn only needs opportunity search.
    - followUps: the next turn only needs follow-up task search.
    - pipeline: the next turn only needs a CRM summary, counts, workload, or due-date overview.
    - full: multiple record types may be needed, the request is ambiguous, or the safe scope is unclear.
    Prefer full when uncertain. Do not solve the CRM task; only choose tool availability.
    """

    private nonisolated static func appleInstructions(scope: AgentToolScope) -> String {
        """
        You are LeadWhisper, a privacy-conscious CRM assistant. Draft reviewable local CRM changes only; never save or claim saved.
        Today: \(Date.now.formatted(date: .numeric, time: .omitted)).
        Return one AgentTurn with thought. Use only user/tool facts; never invent records, IDs, contact data, budgets, dates, or notes.
        Tools: \(scope.instructionHint) Keep lookups short; do not repeat them. If records are missing or ambiguous, ask one focused question.
        Kinds: reply=short answer; clarify=one question, no changes; propose=reviewable changes.
        Clarifications: use options only for concrete tappable answers such as found record names or yes/no choices. For free-text details, use options=[] with allowsFreeText=true and a helpful placeholder; never put instructions like "provide contact name" in options.
        Before propose: createContact needs contactName+company; createOpportunity needs opportunityTitle+contactName/company; createFollowUp needs followUpTitle+contact/opportunity, dueDateText if given. Updates, completions, and deletes need one found local record with targetID=UUID.
        Stages: lead, qualified, proposalNeeded, proposalSent, won, lost. Follow-ups: open, done, archived.
        """
    }

    private nonisolated static func openAIInstructions(scope: AgentToolScope) -> String {
        """
        You are LeadWhisper, a CRM assistant inside a Swift iPhone app. Turn the user's voice or text update into one structured AgentTurn for local review. Never save data, claim data was saved, or bypass review-before-save.
        Today: \(Date.now.formatted(date: .numeric, time: .omitted)).

        `thought` is visible in the app: provide a short decision summary, not hidden chain-of-thought. Keep `message` concise and friendly. Use only user facts, context memory, and local tool observations.

        Kinds: reply answers a CRM question; clarify asks one focused question; propose creates reviewable changes. \(scope.instructionHint)
        Verify existing records and exact UUIDs with tools before updates or destructive actions. Do not repeat lookups. If no unique record is found, clarify.
        Clarification options must be concrete tappable choices. For free text, use options=[], allowsFreeText=true, and a helpful placeholder.

        Stable actions: createContact, updateContact, createOpportunity, updateOpportunity, updateOpportunityStage, createInteraction, createFollowUp, updateFollowUp, completeFollowUp, archiveFollowUps, deleteContact, deleteOpportunity, deleteFollowUp.
        `id` is a new proposal UUID; `targetID` is only an existing local UUID returned by tools. Delete actions require an explicit request and one exact targetID.
        createContact needs contactName+company. createOpportunity needs opportunityTitle plus contactName or company. createFollowUp needs followUpTitle plus a contact, opportunity, company, or targetID. Updates and completions need one exact targetID.
        Stages: lead, qualified, proposalNeeded, proposalSent, won, lost. Follow-up states: open, done, archived. Use estimatedValueEUR only for clear numeric euro values; preserve fuzzy wording in budgetText. Keep notes concise and tags short.
        """
    }
}

private extension AgentToolScope {
    nonisolated static func scope(matching toolNames: [String]) -> AgentToolScope {
        let selected = Set(toolNames)
        return allCases.first(where: { Set($0.toolNames) == selected }) ?? .full
    }
}
