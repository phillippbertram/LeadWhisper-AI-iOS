import BeamBorder
import OSLog
import SwiftData
import SwiftUI

struct AgentComposerView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(\.crmRepository) private var injectedRepository
    @State private var voiceInput = VoiceInputService()
    @State private var agentService = LeadAgentService()
    @State private var speechOutput = SpeechOutputService()
    @State private var transcript = ""
    @State private var isVoiceSession = false
    @State private var analyzeTask: Task<Void, Never>?
    @State private var runResult: AgentRunResult?
    @State private var isProcessing = false
    @State private var statusMessage: String?
    @State private var actionError: PresentableError?

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
                header
                availabilityBanner
                voiceControls
                transcriptEditor
                processingState
                resultSection
                statusSection
            }
            .padding(.horizontal, 16)
            .padding(.top, showTitle ? 18 : 12)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .crmErrorAlert($actionError)
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

    @ViewBuilder
    private var header: some View {
        if showTitle {
            VStack(alignment: .leading, spacing: 6) {
                Text("Voice Agent")
                    .font(.largeTitle.bold())
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                Text("Speak or type a CRM update, then review the local changes before saving.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                recordButton
                    .frame(minWidth: 176)
                resetButton
                    .frame(minWidth: 126)
            }

            VStack(spacing: 10) {
                recordButton
                resetButton
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var recordButton: some View {
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
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!voiceInput.canRecordAudio && !voiceInput.isRecording)
    }

    private var resetButton: some View {
        Button {
            analyzeTask?.cancel()
            voiceInput.reset()
            isVoiceSession = false
            transcript = ""
            runResult = nil
            statusMessage = nil
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    private var transcriptEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcript")
                    .font(.headline)
                Text(voiceInput.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
            .beamBorder(transcriptBeamConfiguration, isEnabled: voiceInput.isRecording && !accessibilityReduceMotion)

            prepareButton
        }
    }

    private var prepareButton: some View {
        Button {
            analyzeTask?.cancel()
            analyzeTask = Task { await analyze() }
        } label: {
            Label("Prepare Changes", systemImage: "sparkles")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
    }

    @ViewBuilder
    private var processingState: some View {
        if isProcessing {
            HStack(spacing: 12) {
                ProgressView()
                Text("Preparing local CRM changes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let runResult {
            AgentResultView(
                runResult: runResult,
                save: saveDraft,
                cancel: cancelDraft,
                answerClarification: selectClarification
            )
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let statusMessage {
            Text(statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
    }

    private func analyze() async {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        AppLog.agent.info("Agent analyze requested transcriptCharacters=\(trimmed.count, privacy: .public)")
        isProcessing = true
        statusMessage = nil
        defer { isProcessing = false }

        let result = await agentService.draft(for: trimmed, repository: injectedRepository.repository(fallback: modelContext))

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
            let result = try ChangeExecutor(repository: injectedRepository.repository(fallback: modelContext)).apply(draft, transcript: transcript)
            statusMessage = "Saved: \(result.changedTitles.joined(separator: ", "))"
            speechOutput.speak(result.spokenSummary)
            runResult = nil
            AppLog.agent.info("Agent draft saved changedTitles=\(result.changedTitles.count, privacy: .public)")
        } catch {
            actionError = PresentableError(error)
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
