import Foundation
import FoundationModels
import Testing
@testable import LeadWhisper

@MainActor
struct AgentServiceTests {
    @Test func lookupModeRoutesCompactToolSets() {
        #expect(LeadAgentService.lookupMode(for: "New contact: Sarah Klein from BluePeak") == .none)

        let updateMode = LeadAgentService.lookupMode(for: "Update for Max Mueller: Set the opportunity to Proposal Sent.")
        #expect(updateMode.contains(.contacts))
        #expect(updateMode.contains(.opportunities))
        #expect(!updateMode.contains(.followUps))

        let rescheduleMode = LeadAgentService.lookupMode(for: "Reschedule Sarah's follow-up to next Tuesday.")
        #expect(rescheduleMode.contains(.followUps))
        #expect(!rescheduleMode.contains(.opportunities))

        let lostMode = LeadAgentService.lookupMode(for: "Mark the BluePeak opportunity as lost and archive follow-ups.")
        #expect(lostMode.contains(.opportunities))
        #expect(lostMode.contains(.followUps))
    }

    @Test func contextWindowErrorUsesFriendlyFallbackMapping() {
        let error = LanguageModelSession.GenerationError.exceededContextWindowSize(
            LanguageModelSession.GenerationError.Context(debugDescription: "too many tokens")
        )
        #expect(LeadAgentService.isContextWindowError(error))
        #expect(LeadAgentService.isContextWindowError(PlainContextError()))
    }
}

private struct PlainContextError: LocalizedError {
    var errorDescription: String? {
        "Exceeded Model context window size"
    }
}
