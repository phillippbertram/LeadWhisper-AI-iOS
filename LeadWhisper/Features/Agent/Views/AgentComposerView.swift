import BeamBorder
import OSLog
import SwiftData
import SwiftUI

struct AgentComposerView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.modelContext) private var modelContext
    @State private var voiceInput = VoiceInputService()
    @State private var agentService = LeadAgentService()
    @State private var speechOutput = SpeechOutputService()
    @State private var transcript = ""
    @State private var isVoiceSession = false
    @State private var analyzeTask: Task<Void, Never>?
    @State private var runResult: AgentRunResult?
    @State private var isProcessing = false
    @State private var statusMessage: String?

    var showTitle = true

    private var transcriptBeamConfiguration: BeamBorderConfiguration {
        BeamBorderConfiguration(
            border: .blue.opacity(isProcessing ? 0.95 : 0.7),
            showsBaseBorder: true,
            beamColors: [.cyan, .blue, .mint, .indigo],
            beamDirection: .both,
            beamBlur: isProcessing ? 18 : 12,
            cornerRadius: 8,
            borderLineWidth: isProcessing ? 1.0 : 0.7,
            baseBorderLineWidth: 0.8,
            animationDuration: isProcessing ? 1.0 : 3.0
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if showTitle {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Voice Agent")
                            .font(.largeTitle.bold())
                        Text("Speak or type a CRM update, then review the local changes before saving.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                availabilityBanner
                voiceControls
                transcriptEditor

                if isProcessing {
                    ProgressView("Preparing local CRM changes")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 18)
                }

                if let runResult {
                    AgentResultView(
                        runResult: runResult,
                        save: saveDraft,
                        cancel: cancelDraft,
                        answerClarification: selectClarification
                    )
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    loadSample()
                } label: {
                    Label("Sample", systemImage: "text.badge.plus")
                }
            }
        }
        .task {
            agentService.prewarm()
        }
        .onChange(of: voiceInput.transcript) { _, newValue in
            // Live recognition owns the transcript only during an active voice
            // session. Manual edits flip the session off, so they are never
            // clobbered by a late partial or final recognition result.
            guard isVoiceSession else { return }
            transcript = newValue
        }
    }

    private var availabilityBanner: some View {
        Label(agentService.availabilityMessage, systemImage: "brain")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var voiceControls: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    if voiceInput.isRecording {
                        voiceInput.stopRecording()
                    } else {
                        isVoiceSession = true
                        await voiceInput.startRecording()
                    }
                }
            } label: {
                Label(voiceInput.recordButtonTitle, systemImage: voiceInput.recordButtonSystemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!voiceInput.canRecordAudio && !voiceInput.isRecording)

            Button {
                analyzeTask?.cancel()
                voiceInput.reset()
                isVoiceSession = false
                transcript = ""
                runResult = nil
                statusMessage = nil
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
        }
        .accessibilityElement(children: .contain)
    }

    private var transcriptEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transcript")
                    .font(.headline)
                Spacer()
                Text(voiceInput.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: Binding(
                get: { transcript },
                set: { newValue in
                    transcript = newValue
                    // A manual edit ends the voice session so recognition
                    // updates stop overwriting what the user typed.
                    isVoiceSession = false
                }
            ))
            .frame(minHeight: 120)
            .padding(8)
            .scrollContentBackground(.hidden)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.blue.opacity(accessibilityReduceMotion ? 0.45 : 0.18), lineWidth: accessibilityReduceMotion ? 1.2 : 0.7)
            }
            .beamBorder(transcriptBeamConfiguration, isEnabled: !accessibilityReduceMotion)

            Button {
                analyzeTask?.cancel()
                analyzeTask = Task { await analyze() }
            } label: {
                Label("Prepare Changes", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
        }
    }

    private func analyze() async {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        AppLog.agent.info("Agent analyze requested transcriptCharacters=\(trimmed.count, privacy: .public)")
        isProcessing = true
        statusMessage = nil
        defer { isProcessing = false }

        let repository = CRMRepository(context: modelContext)
        let result = await agentService.draft(for: trimmed, repository: repository)

        // A newer run (or a reset) may have superseded this one while awaiting.
        guard !Task.isCancelled else {
            AppLog.agent.info("Agent analyze result discarded because the task was cancelled")
            return
        }

        runResult = result
        AppLog.agent.info("Agent analyze finished mockParser=\(result.usedMockParser, privacy: .public) proposedChanges=\(result.draft.proposedChanges.count, privacy: .public)")
    }

    private func saveDraft() {
        guard let draft = runResult?.draft else { return }
        do {
            let repository = CRMRepository(context: modelContext)
            let result = try ChangeExecutor(repository: repository).apply(draft, transcript: transcript)
            statusMessage = "Saved: \(result.changedTitles.joined(separator: ", "))"
            speechOutput.speak(result.spokenSummary)
            runResult = nil
            AppLog.agent.info("Agent draft saved changedTitles=\(result.changedTitles.count, privacy: .public)")
        } catch {
            statusMessage = error.localizedDescription
            AppLog.agent.error("Agent draft save failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func cancelDraft() {
        runResult = nil
        statusMessage = "Draft cancelled"
        AppLog.agent.info("Agent draft cancelled")
    }

    private func selectClarification(_ option: String) {
        let answer = "Clarification answer: \(option)"
        let base = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = base.isEmpty ? answer : "\(base)\n\(answer)"
        isVoiceSession = false
        runResult = nil
        statusMessage = nil

        analyzeTask?.cancel()
        analyzeTask = Task { await analyze() }
    }

    private func loadSample() {
        voiceInput.reset()
        isVoiceSession = false
        transcript = "New contact: Sarah Klein from BluePeak. She needs help with a Flutter app in August. Budget around 20,000 Euro. Create an opportunity, set it to Qualified, and remind me on Friday to send a proposal."
        runResult = nil
        statusMessage = nil
        AppLog.agent.debug("Agent sample transcript loaded")
    }
}
