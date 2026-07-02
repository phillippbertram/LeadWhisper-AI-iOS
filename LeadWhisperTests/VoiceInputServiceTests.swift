import Speech
import Testing
@testable import LeadWhisper

@MainActor
struct VoiceInputServiceTests {
    @Test func voiceAuthorizationStatusesMapToFriendlyFallbackMessages() {
        #expect(VoiceInputService.statusMessage(for: .denied).contains("Type the transcript"))
        #expect(VoiceInputService.statusMessage(for: .restricted).contains("restricted"))
        #expect(VoiceInputService.statusMessage(for: .notDetermined).contains("required"))
    }
}
