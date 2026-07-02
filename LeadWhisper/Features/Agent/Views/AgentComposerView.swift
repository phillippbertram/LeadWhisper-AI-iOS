import BeamBorder
import FactoryKit
import OSLog
import SwiftUI

struct AgentComposerView: View {
    private enum Constants {
        static let bottomAnchor = "agent-bottom-anchor"
    }

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @FocusState private var isInputFocused: Bool
    @State private var voiceInput = VoiceInputService()
    @State private var engine = Container.shared.agentConversationEngine()
    @State private var speechOutput = SpeechOutputService()
    @State private var draftText = ""
    @State private var activeTranscript = ""
    @State private var isVoiceSession = false
    @State private var analyzeTask: Task<Void, Never>?
    @State private var messages: [AgentConversationMessage] = []
    @State private var suggestions: [AgentSuggestion] = []
    @State private var activeResultID: UUID?
    @State private var pendingDestructiveRun: PendingAgentSave?
    @State private var isProcessing = false
    @State private var showsPrivacyInfo = false
    @State private var actionError: PresentableError?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty, !isProcessing {
                        AgentEmptyStateView(suggestions: suggestions) { prompt in
                            submit(prompt)
                        }
                    }

                    ForEach(messages) { message in
                        AgentMessageRow(
                            message: message,
                            activeResultID: activeResultID,
                            save: saveDraft,
                            cancel: cancelDraft,
                            answerClarification: submit
                        )
                        .id(message.id)
                    }

                    if isProcessing {
                        ProcessingBubble(activity: engine.currentActivity)
                            .id("processing")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Constants.bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                AgentInputBar(
                    text: $draftText,
                    isInputFocused: $isInputFocused,
                    isRecording: voiceInput.isRecording,
                    canRecord: voiceInput.canRecordAudio,
                    statusMessage: voiceInput.statusMessage,
                    isProcessing: isProcessing,
                    accessibilityReduceMotion: accessibilityReduceMotion,
                    contextUsage: engine.contextWindowUsage(for: draftText),
                    send: { submitDraftText() },
                    toggleRecording: toggleRecording
                )
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 10)
                .background(.ultraThinMaterial)
            }
            .onAppear {
                refreshSuggestions()
                scrollToBottom(proxy)
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: isProcessing) { _, _ in
                scrollToBottom(proxy)
            }
        }
        .crmErrorAlert($actionError)
        .confirmationDialog(
            "Delete local data?",
            isPresented: .init(isPresenting: $pendingDestructiveRun),
            titleVisibility: .visible,
            presenting: pendingDestructiveRun
        ) { pending in
            Button("Delete and Save Changes", role: .destructive) {
                applyDraft(pending.draft, transcript: pending.transcript, allowDestructive: true)
                pendingDestructiveRun = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDestructiveRun = nil
            }
        } message: { _ in
            Text("This draft deletes local CRM records. Review the cards carefully before confirming.")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsPrivacyInfo = true
                } label: {
                    Label("Privacy", systemImage: "lock.shield")
                }
                .popover(isPresented: $showsPrivacyInfo) {
                    AgentPrivacyPopover(availabilityMessage: engine.availabilityMessage)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    resetConversation()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .disabled(!canResetConversation)
            }
        }
        .task {
            engine.prewarm()
        }
        .onChange(of: voiceInput.transcript) { _, newValue in
            guard isVoiceSession else { return }
            draftText = newValue
        }
    }

    private var canResetConversation: Bool {
        !messages.isEmpty ||
            !draftText.isEmpty ||
            isProcessing ||
            activeResultID != nil
    }

    private func refreshSuggestions() {
        do {
            let snapshot = try Container.shared.crmRepository().snapshot()
            suggestions = AgentSuggestionBuilder.suggestions(from: snapshot)
        } catch {
            AppLog.agent.error("Agent suggestions snapshot failed error=\(error.localizedDescription, privacy: .public)")
            suggestions = AgentSuggestionBuilder.suggestions(from: CRMDataSnapshot(contacts: [], opportunities: [], followUps: []))
        }
    }

    private func submitDraftText() {
        submit(draftText)
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isProcessing else { return }

        if voiceInput.isRecording {
            voiceInput.stopRecording()
        }

        draftText = ""
        dismissKeyboard()
        isVoiceSession = false
        activeResultID = nil
        messages.append(.user(trimmed))
        activeTranscript = activeTranscript.isEmpty ? trimmed : "\(activeTranscript)\n\(trimmed)"

        analyzeTask?.cancel()
        analyzeTask = Task { await analyze(message: trimmed) }
    }

    private func analyze(message: String) async {
        AppLog.agent.info("Agent analyze requested messageCharacters=\(message.count, privacy: .public)")
        isProcessing = true
        defer { isProcessing = false }

        var result = await engine.send(message)

        guard !Task.isCancelled else {
            AppLog.agent.info("Agent turn result discarded because the task was cancelled")
            return
        }

        if !result.draft.proposedChanges.isEmpty {
            result.diffs = Container.shared.changeDiffBuilder().diffs(for: result.draft.proposedChanges)
        }

        if result.kind == .reply, result.errorMessage == nil {
            let text = result.message.nilIfBlank ?? "Tell me which contact, opportunity, or follow-up you want to change and what should happen next."
            messages.append(.assistant(text, detail: nil, systemImage: "sparkles"))
        } else {
            activeResultID = result.id
            messages.append(.result(result, transcript: activeTranscript))
        }
        AppLog.agent.info("Agent analyze finished kind=\(result.kind.rawValue, privacy: .public) proposedChanges=\(result.draft.proposedChanges.count, privacy: .public) hasError=\(result.errorMessage == nil ? "false" : "true", privacy: .public)")
    }

    private func saveDraft(_ runResult: AgentRunResult, transcript: String, selectedChangeIDs: Set<String>) {
        guard runResult.id == activeResultID else { return }

        var draft = runResult.draft
        draft.proposedChanges = draft.proposedChanges.filter { selectedChangeIDs.contains($0.id) }
        guard !draft.proposedChanges.isEmpty else { return }

        if draft.containsDestructiveChange {
            pendingDestructiveRun = PendingAgentSave(draft: draft, transcript: transcript)
            return
        }

        applyDraft(draft, transcript: transcript, allowDestructive: false)
    }

    private func applyDraft(_ draft: AgentDraft, transcript: String, allowDestructive: Bool) {
        do {
            let result = try Container.shared.changeExecutor().apply(
                draft,
                transcript: transcript,
                allowDestructive: allowDestructive
            )
            activeResultID = nil
            activeTranscript = ""
            engine.noteDraftSaved()
            messages.append(.receipt(result.changedTitles))
            speechOutput.speak(result.spokenSummary)
            AppLog.agent.info("Agent draft saved changedTitles=\(result.changedTitles.count, privacy: .public)")
        } catch {
            actionError = PresentableError(error)
            AppLog.agent.error("Agent draft save failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func cancelDraft(_ runResult: AgentRunResult) {
        guard runResult.id == activeResultID else { return }
        activeResultID = nil
        activeTranscript = ""
        engine.noteDraftCancelled()
        messages.append(.assistant("Draft cancelled", detail: nil, systemImage: "xmark.circle"))
        AppLog.agent.info("Agent draft cancelled")
    }

    private func toggleRecording() {
        Task {
            if voiceInput.isRecording {
                voiceInput.stopRecording()
            } else {
                isVoiceSession = true
                await voiceInput.startRecording()
            }
        }
    }

    private func resetConversation() {
        analyzeTask?.cancel()
        voiceInput.reset()
        engine.reset()
        draftText = ""
        activeTranscript = ""
        isVoiceSession = false
        dismissKeyboard()
        isProcessing = false
        activeResultID = nil
        pendingDestructiveRun = nil
        messages = []
        refreshSuggestions()
        AppLog.agent.debug("Agent conversation reset")
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let action = {
            proxy.scrollTo(Constants.bottomAnchor, anchor: .bottom)
        }

        if accessibilityReduceMotion {
            action()
        } else {
            withAnimation(.snappy(duration: 0.22)) {
                action()
            }
        }
    }

    private func dismissKeyboard() {
        isInputFocused = false
    }
}

private struct PendingAgentSave: Identifiable {
    let id = UUID()
    let draft: AgentDraft
    let transcript: String
}

private struct AgentConversationMessage: Identifiable {
    let id = UUID()
    var content: AgentMessageContent

    static func user(_ text: String) -> AgentConversationMessage {
        AgentConversationMessage(content: .user(text))
    }

    static func assistant(_ title: String, detail: String?, systemImage: String) -> AgentConversationMessage {
        AgentConversationMessage(content: .assistant(title: title, detail: detail, systemImage: systemImage))
    }

    static func result(_ runResult: AgentRunResult, transcript: String) -> AgentConversationMessage {
        AgentConversationMessage(content: .result(runResult, transcript: transcript))
    }

    static func receipt(_ changedTitles: [String]) -> AgentConversationMessage {
        AgentConversationMessage(content: .receipt(changedTitles))
    }

    var resultID: UUID? {
        if case .result(let runResult, _) = content {
            return runResult.id
        }
        return nil
    }
}

private enum AgentMessageContent {
    case assistant(title: String, detail: String?, systemImage: String)
    case user(String)
    case result(AgentRunResult, transcript: String)
    case receipt([String])
}

private struct AgentMessageRow: View {
    let message: AgentConversationMessage
    let activeResultID: UUID?
    let save: (AgentRunResult, String, Set<String>) -> Void
    let cancel: (AgentRunResult) -> Void
    let answerClarification: (String) -> Void

    var body: some View {
        switch message.content {
        case .assistant(let title, let detail, let systemImage):
            AssistantBubble(title: title, detail: detail, systemImage: systemImage)

        case .user(let text):
            UserBubble(text: text)

        case .result(let runResult, let transcript):
            AgentResultBubble(
                runResult: runResult,
                transcript: transcript,
                isActive: runResult.id == activeResultID,
                save: save,
                cancel: cancel,
                answerClarification: answerClarification
            )

        case .receipt(let changedTitles):
            ReceiptBubble(changedTitles: changedTitles)
        }
    }
}

private struct AssistantBubble: View {
    let title: String
    let detail: String?
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(systemImage: systemImage)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 36)
        }
    }
}

private struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 46)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    LinearGradient(
                        colors: [.blue, .cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .shadow(color: .blue.opacity(0.12), radius: 10, x: 0, y: 5)
        }
    }
}

private struct AgentResultBubble: View {
    let runResult: AgentRunResult
    let transcript: String
    let isActive: Bool
    let save: (AgentRunResult, String, Set<String>) -> Void
    let cancel: (AgentRunResult) -> Void
    let answerClarification: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(systemImage: avatarImage)
            AgentResultView(
                runResult: runResult,
                showsActions: isActive,
                save: { selectedChangeIDs in save(runResult, transcript, selectedChangeIDs) },
                cancel: { cancel(runResult) },
                answerClarification: answerClarification
            )
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var avatarImage: String {
        if runResult.draft.containsDestructiveChange {
            return "exclamationmark.triangle.fill"
        }
        return runResult.kind == .clarify ? "questionmark.bubble" : "sparkles"
    }
}

private struct ReceiptBubble: View {
    let changedTitles: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(systemImage: "checkmark.seal.fill")
            VStack(alignment: .leading, spacing: 8) {
                Text("Saved to your CRM")
                    .font(.subheadline.weight(.semibold))
                if !changedTitles.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(changedTitles.enumerated()), id: \.offset) { _, title in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                Text(title)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 36)
        }
    }
}

private struct AgentAvatar: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.footnote.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(
                LinearGradient(colors: [.cyan, .blue, .green], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Circle()
            )
            .shadow(color: .blue.opacity(0.18), radius: 8, x: 0, y: 4)
    }
}

private struct ProcessingBubble: View {
    var activity: String?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AgentAvatar(systemImage: "brain")
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                TypingDots()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityLabel("LeadWhisper is thinking")
            Spacer(minLength: 36)
        }
    }
}

private struct AgentPrivacyPopover: View {
    let availabilityMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Private CRM agent", systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
            Text(availabilityMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Everything runs on this device. Proposed changes are only saved after you review them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: 300, alignment: .leading)
        .presentationCompactAdaptation(.popover)
    }
}

private struct TypingDots: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(.secondary)
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct AgentInputBar: View {
    @Binding var text: String
    let isInputFocused: FocusState<Bool>.Binding
    let isRecording: Bool
    let canRecord: Bool
    let statusMessage: String
    let isProcessing: Bool
    let accessibilityReduceMotion: Bool
    let contextUsage: AgentContextWindowUsage
    let send: () -> Void
    let toggleRecording: () -> Void

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isProcessing
    }

    private var beamConfiguration: BeamBorderConfiguration {
        BeamBorderConfiguration(
            border: .blue.opacity(isProcessing ? 0.95 : 0.72),
            showsBaseBorder: true,
            beamColors: [.cyan, .blue, .green],
            beamDirection: .both,
            beamBlur: isProcessing ? 18 : 12,
            cornerRadius: 24,
            borderLineWidth: isProcessing ? 1.0 : 0.7,
            baseBorderLineWidth: 0.8,
            animationDuration: isProcessing ? 1.0 : 2.6
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("Tell me what changed with a lead...", text: $text, axis: .vertical)
                .focused(isInputFocused)
                .font(.body)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack(alignment: .center, spacing: 8) {
                ComposerIconButton(
                    systemImage: isRecording ? "stop.fill" : canRecord ? "mic.fill" : "mic.slash.fill",
                    tint: isRecording ? .red : .blue,
                    isEnabled: canRecord || isRecording,
                    accessibilityLabel: isRecording ? "Stop recording" : "Start recording",
                    action: toggleRecording
                )

                HStack(spacing: 6) {
                    Image(systemName: isProcessing ? "brain" : isRecording ? "waveform" : "lock.shield")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isProcessing || isRecording ? .blue : .secondary)
                    Text(statusLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
                .padding(.leading, 2)

                Spacer(minLength: 0)
                ContextWindowUsageRing(usage: contextUsage)
                ComposerIconButton(
                    systemImage: "arrow.up",
                    tint: .blue,
                    isEnabled: canSend,
                    accessibilityLabel: "Send to LeadWhisper",
                    action: send
                )
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.blue.opacity(accessibilityReduceMotion ? 0.42 : 0.16), lineWidth: accessibilityReduceMotion ? 1.2 : 0.7)
        }
        .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 8)
        .beamBorder(beamConfiguration, isEnabled: (isRecording || isProcessing) && !accessibilityReduceMotion)
    }

    private var statusLine: String {
        if isRecording {
            return "Listening..."
        }
        return statusMessage
    }
}

private struct ContextWindowUsageRing: View {
    let usage: AgentContextWindowUsage

    private var tint: Color {
        switch usage.fraction {
        case ..<0.65:
            .blue
        case ..<0.85:
            .orange
        default:
            .red
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.tertiarySystemFill), lineWidth: 3)
            Circle()
                .trim(from: 0, to: usage.fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "memorychip")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 26, height: 26)
        .accessibilityLabel("Estimated context window usage")
        .accessibilityValue(usage.accessibilityValue)
        .help("Estimated context: \(usage.usedTokens)/\(usage.maximumTokens) tokens")
    }
}

private struct ComposerIconButton: View {
    let systemImage: String
    let tint: Color
    let isEnabled: Bool
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(isEnabled ? tint : .secondary)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(isEnabled ? tint.opacity(0.14) : Color(.tertiarySystemFill))
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }
}
