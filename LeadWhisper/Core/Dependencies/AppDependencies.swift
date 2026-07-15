import FactoryKit
import SwiftData

extension Container {
    @MainActor
    var modelContainer: Factory<ModelContainer> {
        self {
            LeadWhisperModelContainerFactory.makePersistentContainer()
        }
        .singleton
    }

    @MainActor
    var crmRepository: Factory<CRMRepository> {
        self {
            CRMRepository(context: self.modelContainer().mainContext)
        }
        .singleton
    }

    @MainActor
    var agentToolDataSource: Factory<AgentToolDataSource> {
        self {
            AgentToolDataSource.live(repository: self.crmRepository())
        }
    }

    @MainActor
    var agentCredentialStore: Factory<AgentCredentialStore> {
        self {
            AgentCredentialStore()
        }
        .singleton
    }

    @MainActor
    var leadWhisperAgentFactory: Factory<LeadWhisperAgentFactory> {
        self {
            LeadWhisperAgentFactory(credentialStore: self.agentCredentialStore())
        }
        .singleton
    }

    @MainActor
    var agentConversationEngine: Factory<AgentConversationEngine> {
        self {
            AgentConversationEngine(
                toolDataSource: self.agentToolDataSource(),
                agentFactory: self.leadWhisperAgentFactory()
            )
        }
    }

    @MainActor
    var changeDiffBuilder: Factory<ChangeDiffBuilder> {
        self {
            ChangeDiffBuilder(repository: self.crmRepository())
        }
    }

    @MainActor
    var changeExecutor: Factory<ChangeExecutor> {
        self {
            ChangeExecutor(repository: self.crmRepository())
        }
    }
}
