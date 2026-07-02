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
    @State private var agentService = Container.shared.leadAgentService()
    @State private var speechOutput = SpeechOutputService()
    @State private var draftText = ""
    @State private var activeTranscript = ""
    @State private var guidedWorkflow: AgentGuidedWorkflow?
    @State private var isVoiceSession = false
    @State private var analyzeTask: Task<Void, Never>?
    @State private var messages = AgentConversationMessage.initialMessages
    @State private var activeResultID: UUID?
    @State private var pendingDestructiveRun: PendingAgentSave?
    @State private var isProcessing = false
    @State private var actionError: PresentableError?

    var showTitle = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if showTitle {
                        header
                    }

                    localStatusCard

                    ForEach(messages) { message in
                        AgentMessageRow(
                            message: message,
                            activeResultID: activeResultID,
                            save: saveDraft,
                            cancel: cancelDraft,
                            answerClarification: answerClarification,
                            answerGuidance: submit
                        )
                        .id(message.id)
                    }

                    if shouldShowStarterPrompts {
                        StarterPromptStrip { prompt in
                            submit(prompt)
                        }
                    }

                    if isProcessing {
                        ProcessingBubble()
                            .id("processing")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Constants.bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.top, showTitle ? 18 : 12)
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
                    send: { submitDraftText() },
                    toggleRecording: toggleRecording
                )
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 10)
                .background(.ultraThinMaterial)
            }
            .onAppear {
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
                applyDraft(pending.runResult, transcript: pending.transcript, allowDestructive: true)
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
                    resetConversation()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .disabled(!canResetConversation)
            }
        }
        .task {
            agentService.prewarm()
        }
        .onChange(of: voiceInput.transcript) { _, newValue in
            guard isVoiceSession else { return }
            draftText = newValue
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent")
                .font(.largeTitle.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Text("Chat through lead updates, follow-ups, and pipeline changes. I'll ask before I draft anything risky.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var localStatusCard: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(.blue.opacity(0.14))
                Image(systemName: "lock.shield")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("Private CRM agent")
                    .font(.subheadline.weight(.semibold))
                Text("\(agentService.availabilityMessage) - review before save")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "sparkles")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.mint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var shouldShowStarterPrompts: Bool {
        !messages.contains { $0.isUserMessage } && !isProcessing
    }

    private var canResetConversation: Bool {
        messages.count > AgentConversationMessage.initialMessages.count ||
            !draftText.isEmpty ||
            isProcessing ||
            activeResultID != nil
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

        if continueGuidedWorkflow(with: trimmed) {
            return
        }

        if routeGuidedRequest(trimmed) {
            return
        }

        activeTranscript = trimmed
        analyzeTask?.cancel()
        analyzeTask = Task { await analyze(transcript: trimmed) }
    }

    private func analyze(transcript: String) async {
        AppLog.agent.info("Agent analyze requested transcriptCharacters=\(transcript.count, privacy: .public)")
        isProcessing = true
        defer { isProcessing = false }

        let result = await agentService.draft(for: transcript)

        guard !Task.isCancelled else {
            AppLog.agent.info("Agent analyze result discarded because the task was cancelled")
            return
        }

        activeResultID = result.id
        messages.append(.result(result, transcript: transcript))
        AppLog.agent.info("Agent analyze finished proposedChanges=\(result.draft.proposedChanges.count, privacy: .public) hasError=\(result.errorMessage == nil ? "false" : "true", privacy: .public)")
    }

    private func saveDraft(_ runResult: AgentRunResult, transcript: String) {
        guard runResult.id == activeResultID else { return }
        if runResult.draft.containsDestructiveChange {
            pendingDestructiveRun = PendingAgentSave(runResult: runResult, transcript: transcript)
            return
        }

        applyDraft(runResult, transcript: transcript, allowDestructive: false)
    }

    private func applyDraft(_ runResult: AgentRunResult, transcript: String, allowDestructive: Bool) {
        do {
            let result = try Container.shared.changeExecutor().apply(
                runResult.draft,
                transcript: transcript,
                allowDestructive: allowDestructive
            )
            activeResultID = nil
            activeTranscript = ""
            let detail = result.changedTitles.isEmpty ? nil : result.changedTitles.joined(separator: ", ")
            messages.append(.assistant("Saved changes", detail: detail, systemImage: "checkmark.seal.fill"))
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
        messages.append(.assistant("Draft cancelled", detail: nil, systemImage: "xmark.circle"))
        AppLog.agent.info("Agent draft cancelled")
    }

    private func answerClarification(_ option: String) {
        guard let activeResultID,
              messages.contains(where: { $0.resultID == activeResultID })
        else { return }

        let answer = "Clarification answer: \(option)"
        let transcript = activeTranscript.isEmpty ? answer : "\(activeTranscript)\n\(answer)"
        activeTranscript = transcript
        messages.append(.user(option))
        dismissKeyboard()
        self.activeResultID = nil
        guidedWorkflow = nil
        analyzeTask?.cancel()
        analyzeTask = Task { await analyze(transcript: transcript) }
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
        draftText = ""
        activeTranscript = ""
        guidedWorkflow = nil
        isVoiceSession = false
        dismissKeyboard()
        isProcessing = false
        activeResultID = nil
        pendingDestructiveRun = nil
        messages = AgentConversationMessage.initialMessages
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

    private func routeGuidedRequest(_ text: String) -> Bool {
        let snapshot = currentSnapshot()
        let guidance = AgentConversationPlanner.guidance(for: text, snapshot: snapshot)

        switch guidance {
        case .none:
            return false
        case .notice(let message):
            messages.append(.guidance(message))
            AppLog.agent.info("Agent guided notice shown")
            return true
        case .workflow(let workflow, let message):
            guidedWorkflow = workflow
            activeTranscript = text
            messages.append(.guidance(message))
            AppLog.agent.info("Agent guided workflow started kind=\(workflow.kind.logLabel, privacy: .public)")
            return true
        }
    }

    private func continueGuidedWorkflow(with answer: String) -> Bool {
        guard let workflow = guidedWorkflow else { return false }

        let result = workflow.advance(with: answer, snapshot: currentSnapshot())
        switch result {
        case .ask(let nextWorkflow, let message):
            guidedWorkflow = nextWorkflow
            messages.append(.guidance(message))
            AppLog.agent.info("Agent guided workflow continued kind=\(nextWorkflow.kind.logLabel, privacy: .public)")
        case .complete(let transcript):
            guidedWorkflow = nil
            activeTranscript = transcript
            analyzeTask?.cancel()
            analyzeTask = Task { await analyze(transcript: transcript) }
            AppLog.agent.info("Agent guided workflow completed kind=\(workflow.kind.logLabel, privacy: .public)")
        case .notice(let message):
            guidedWorkflow = nil
            messages.append(.guidance(message))
            AppLog.agent.info("Agent guided workflow stopped kind=\(workflow.kind.logLabel, privacy: .public)")
        }

        return true
    }

    private func currentSnapshot() -> CRMDataSnapshot {
        do {
            return try Container.shared.crmRepository().snapshot()
        } catch {
            AppLog.agent.error("Agent guided snapshot failed error=\(error.localizedDescription, privacy: .public)")
            return CRMDataSnapshot(contacts: [], opportunities: [], followUps: [])
        }
    }
}

private struct PendingAgentSave: Identifiable {
    let id = UUID()
    let runResult: AgentRunResult
    let transcript: String
}

private struct AgentConversationMessage: Identifiable {
    let id = UUID()
    var content: AgentMessageContent

    static let initialMessages = [
        AgentConversationMessage(content: .assistant(
            title: "What changed in your CRM?",
            detail: "Start with a sentence like \"I have a new lead\" or paste call notes. I'll guide you until there is enough real CRM data for a review card.",
            systemImage: "sparkles"
        ))
    ]

    static func user(_ text: String) -> AgentConversationMessage {
        AgentConversationMessage(content: .user(text))
    }

    static func assistant(_ title: String, detail: String?, systemImage: String) -> AgentConversationMessage {
        AgentConversationMessage(content: .assistant(title: title, detail: detail, systemImage: systemImage))
    }

    static func result(_ runResult: AgentRunResult, transcript: String) -> AgentConversationMessage {
        AgentConversationMessage(content: .result(runResult, transcript: transcript))
    }

    static func guidance(_ message: AgentGuidanceMessage) -> AgentConversationMessage {
        AgentConversationMessage(content: .guidance(message))
    }

    var isUserMessage: Bool {
        if case .user = content {
            return true
        }
        return false
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
    case guidance(AgentGuidanceMessage)
    case result(AgentRunResult, transcript: String)
}

private struct AgentMessageRow: View {
    let message: AgentConversationMessage
    let activeResultID: UUID?
    let save: (AgentRunResult, String) -> Void
    let cancel: (AgentRunResult) -> Void
    let answerClarification: (String) -> Void
    let answerGuidance: (String) -> Void

    var body: some View {
        switch message.content {
        case .assistant(let title, let detail, let systemImage):
            AssistantBubble(title: title, detail: detail, systemImage: systemImage)

        case .user(let text):
            UserBubble(text: text)

        case .guidance(let guidance):
            GuidanceBubble(message: guidance, select: answerGuidance)

        case .result(let runResult, let transcript):
            AgentResultBubble(
                runResult: runResult,
                transcript: transcript,
                isActive: runResult.id == activeResultID,
                save: save,
                cancel: cancel,
                answerClarification: answerClarification
            )
        }
    }
}

private struct GuidanceBubble: View {
    let message: AgentGuidanceMessage
    let select: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(systemImage: message.systemImage)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.title)
                        .font(.subheadline.weight(.semibold))
                    if let detail = message.detail?.nilIfBlank {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !message.options.isEmpty {
                    FlowOptionGroup(options: message.options, select: select)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 34)
        }
    }
}

private struct FlowOptionGroup: View {
    let options: [AgentGuidanceOption]
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(options) { option in
                Button {
                    select(option.prompt)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: option.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(option.tint)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let subtitle = option.subtitle?.nilIfBlank {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.message")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 3)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(option.tint.opacity(0.16))
                    }
                }
                .buttonStyle(.plain)
            }
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
    let save: (AgentRunResult, String) -> Void
    let cancel: (AgentRunResult) -> Void
    let answerClarification: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(systemImage: runResult.draft.containsDestructiveChange ? "exclamationmark.triangle.fill" : "sparkles")
            AgentResultView(
                runResult: runResult,
                showsActions: isActive,
                save: { save(runResult, transcript) },
                cancel: { cancel(runResult) },
                answerClarification: answerClarification
            )
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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

private struct StarterPromptStrip: View {
    let submit: (String) -> Void

    private let prompts: [StarterPrompt] = [
        StarterPrompt(
            title: "New lead",
            systemImage: "person.crop.circle.badge.plus",
            prompt: "I have a new lead"
        ),
        StarterPrompt(
            title: "Paste call notes",
            systemImage: "text.bubble",
            prompt: "Log a call with Sarah Klein at BluePeak: she needs help with a Flutter app in August, budget around 20,000 Euro. Create the lead, opportunity, and a proposal follow-up for Friday."
        ),
        StarterPrompt(
            title: "Pipeline stage",
            systemImage: "chart.line.uptrend.xyaxis",
            prompt: "Move Max Mueller's opportunity to proposal sent and note that he wants to align internally next week."
        ),
        StarterPrompt(
            title: "Create follow-up",
            systemImage: "calendar.badge.plus",
            prompt: "Create a follow-up for Sarah Klein to send a short technical concept next Tuesday."
        ),
        StarterPrompt(
            title: "Find match",
            systemImage: "questionmark.circle",
            prompt: "Update Max: he wants a proposal next week."
        ),
        StarterPrompt(
            title: "Mark done",
            systemImage: "checkmark.circle",
            prompt: "Mark the proposal follow-up as done."
        ),
        StarterPrompt(
            title: "Delete follow-up",
            systemImage: "trash",
            prompt: "Delete the proposal follow-up."
        )
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(prompts) { prompt in
                    Button {
                        submit(prompt.prompt)
                    } label: {
                        Label(prompt.title, systemImage: prompt.systemImage)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(.blue.opacity(0.16))
                            }
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct StarterPrompt: Identifiable {
    let id = UUID()
    var title: String
    var systemImage: String
    var prompt: String
}

private struct AgentInputBar: View {
    @Binding var text: String
    let isInputFocused: FocusState<Bool>.Binding
    let isRecording: Bool
    let canRecord: Bool
    let statusMessage: String
    let isProcessing: Bool
    let accessibilityReduceMotion: Bool
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .bottom, spacing: 8) {
                ComposerIconButton(
                    systemImage: isRecording ? "stop.fill" : canRecord ? "mic.fill" : "mic.slash.fill",
                    tint: isRecording ? .red : .blue,
                    isEnabled: canRecord || isRecording,
                    accessibilityLabel: isRecording ? "Stop recording" : "Start recording",
                    action: toggleRecording
                )

                TextField("Tell me what changed with a lead...", text: $text, axis: .vertical)
                    .focused(isInputFocused)
                    .font(.body)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                ComposerIconButton(
                    systemImage: "arrow.up",
                    tint: .blue,
                    isEnabled: canSend,
                    accessibilityLabel: "Send to LeadWhisper",
                    action: send
                )
            }

            HStack(spacing: 6) {
                Image(systemName: isProcessing ? "brain" : isRecording ? "waveform" : "lock.shield")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isProcessing || isRecording ? .blue : .secondary)
                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
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

private struct AgentGuidanceMessage: Identifiable {
    let id = UUID()
    var title: String
    var detail: String?
    var systemImage: String
    var options: [AgentGuidanceOption] = []
}

private struct AgentGuidanceOption: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String?
    var prompt: String
    var systemImage: String
    var tint: Color = .blue
}

private enum AgentGuidedRoute {
    case none
    case notice(AgentGuidanceMessage)
    case workflow(AgentGuidedWorkflow, AgentGuidanceMessage)
}

private enum AgentGuidedWorkflowResult {
    case ask(AgentGuidedWorkflow, AgentGuidanceMessage)
    case complete(String)
    case notice(AgentGuidanceMessage)
}

private struct AgentGuidedWorkflow {
    enum Kind {
        case newLead
        case deleteContact
        case deleteOpportunity
        case deleteFollowUp
        case updateContact
        case createFollowUp
        case completeFollowUp

        var logLabel: String {
            switch self {
            case .newLead: "newLead"
            case .deleteContact: "deleteContact"
            case .deleteOpportunity: "deleteOpportunity"
            case .deleteFollowUp: "deleteFollowUp"
            case .updateContact: "updateContact"
            case .createFollowUp: "createFollowUp"
            case .completeFollowUp: "completeFollowUp"
            }
        }
    }

    enum Step {
        case leadName
        case leadCompany
        case leadNeed
        case leadFollowUpChoice
        case leadFollowUpDetail
        case targetContact
        case targetOpportunity
        case targetFollowUp
        case updateDetail
        case followUpDetail
    }

    var kind: Kind
    var step: Step
    var fields: [String: String] = [:]

    func advance(with answer: String, snapshot: CRMDataSnapshot) -> AgentGuidedWorkflowResult {
        let value = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return .ask(self, questionForCurrentStep(snapshot: snapshot))
        }

        var next = self
        switch (kind, step) {
        case (.newLead, .leadName):
            next.fields["contactName"] = value
            next.step = .leadCompany
            return .ask(next, next.questionForCurrentStep(snapshot: snapshot))

        case (.newLead, .leadCompany):
            next.fields["company"] = value
            next.step = .leadNeed
            return .ask(next, next.questionForCurrentStep(snapshot: snapshot))

        case (.newLead, .leadNeed):
            next.fields["need"] = value
            next.step = .leadFollowUpChoice
            return .ask(next, next.questionForCurrentStep(snapshot: snapshot))

        case (.newLead, .leadFollowUpChoice):
            if value.searchKey.contains("no") || value.searchKey.contains("skip") || value.searchKey.contains("none") {
                return .complete(next.newLeadTranscript())
            }
            next.step = .leadFollowUpDetail
            return .ask(next, next.questionForCurrentStep(snapshot: snapshot))

        case (.newLead, .leadFollowUpDetail):
            next.fields["followUp"] = value
            return .complete(next.newLeadTranscript())

        case (.deleteContact, .targetContact), (.updateContact, .targetContact):
            let matches = AgentConversationPlanner.matchingContacts(value, snapshot: snapshot)
            guard !matches.isEmpty else {
                return .ask(next, AgentConversationPlanner.contactQuestion(
                    title: "I could not find that contact",
                    detail: "Choose an existing contact, or create the contact first.",
                    snapshot: snapshot
                ))
            }
            guard matches.count == 1, let contact = matches.first else {
                return .ask(next, AgentConversationPlanner.contactQuestion(
                    title: "Which contact do you mean?",
                    detail: "I found more than one possible match.",
                    snapshot: CRMDataSnapshot(contacts: matches, opportunities: snapshot.opportunities, followUps: snapshot.followUps)
                ))
            }
            next.fields["contactName"] = contact.fullName
            next.fields["company"] = contact.company
            if kind == .deleteContact {
                return .complete("Delete the existing local contact \(contact.fullName) at \(contact.company). Use only this local record.")
            }
            next.step = .updateDetail
            return .ask(next, next.questionForCurrentStep(snapshot: snapshot))

        case (.updateContact, .updateDetail):
            guard let name = fields["contactName"], let company = fields["company"] else {
                return .notice(AgentConversationPlanner.genericRecoveryNotice())
            }
            return .complete("Update the existing local contact \(name) at \(company): \(value). Use only this local record.")

        case (.deleteOpportunity, .targetOpportunity):
            let matches = AgentConversationPlanner.matchingOpportunities(value, snapshot: snapshot)
            guard !matches.isEmpty else {
                return .ask(next, AgentConversationPlanner.opportunityQuestion(
                    title: "I could not find that opportunity",
                    detail: "Choose an existing opportunity, or create one from a lead first.",
                    opportunities: snapshot.opportunities
                ))
            }
            guard matches.count == 1, let opportunity = matches.first else {
                return .ask(next, AgentConversationPlanner.opportunityQuestion(
                    title: "Which opportunity should I use?",
                    detail: "I found more than one possible match.",
                    opportunities: matches
                ))
            }
            return .complete("Delete the existing local opportunity \(opportunity.title) at \(opportunity.company). Use only this local record.")

        case (.deleteFollowUp, .targetFollowUp), (.completeFollowUp, .targetFollowUp):
            let matches = AgentConversationPlanner.matchingFollowUps(value, snapshot: snapshot)
            guard !matches.isEmpty else {
                return .ask(next, AgentConversationPlanner.followUpQuestion(
                    title: "I could not find that follow-up",
                    detail: "Choose an existing follow-up, or create one first.",
                    followUps: snapshot.followUps
                ))
            }
            guard matches.count == 1, let followUp = matches.first else {
                return .ask(next, AgentConversationPlanner.followUpQuestion(
                    title: "Which follow-up do you mean?",
                    detail: "I found more than one possible match.",
                    followUps: matches
                ))
            }
            if kind == .deleteFollowUp {
                return .complete("Delete the existing local follow-up \(followUp.title). Use only this local record.")
            }
            return .complete("Mark the existing local follow-up \(followUp.title) as done. Use only this local record.")

        case (.createFollowUp, .targetContact):
            let matches = AgentConversationPlanner.matchingContacts(value, snapshot: snapshot)
            guard !matches.isEmpty else {
                return .ask(next, AgentConversationPlanner.contactQuestion(
                    title: "Who is this follow-up for?",
                    detail: "Choose an existing contact, or create the lead first.",
                    snapshot: snapshot
                ))
            }
            guard matches.count == 1, let contact = matches.first else {
                return .ask(next, AgentConversationPlanner.contactQuestion(
                    title: "Which contact should get the follow-up?",
                    detail: "I found more than one possible match.",
                    snapshot: CRMDataSnapshot(contacts: matches, opportunities: snapshot.opportunities, followUps: snapshot.followUps)
                ))
            }
            next.fields["contactName"] = contact.fullName
            next.fields["company"] = contact.company
            next.step = .followUpDetail
            return .ask(next, next.questionForCurrentStep(snapshot: snapshot))

        case (.createFollowUp, .followUpDetail):
            guard let name = fields["contactName"], let company = fields["company"] else {
                return .notice(AgentConversationPlanner.genericRecoveryNotice())
            }
            return .complete("Create a follow-up for the existing local contact \(name) at \(company): \(value).")

        default:
            return .notice(AgentConversationPlanner.genericRecoveryNotice())
        }
    }

    func questionForCurrentStep(snapshot: CRMDataSnapshot) -> AgentGuidanceMessage {
        switch (kind, step) {
        case (.newLead, .leadName):
            AgentGuidanceMessage(
                title: "Great. Who is the lead?",
                detail: "Send the person's full name. I will ask for the company next.",
                systemImage: "person.crop.circle.badge.plus"
            )
        case (.newLead, .leadCompany):
            AgentGuidanceMessage(
                title: "Which company are they with?",
                detail: "A company or organization keeps the local CRM record usable later.",
                systemImage: "building.2"
            )
        case (.newLead, .leadNeed):
            AgentGuidanceMessage(
                title: "What should I capture about the lead?",
                detail: "Add the need, budget, timing, or call notes. I will not invent missing details.",
                systemImage: "note.text"
            )
        case (.newLead, .leadFollowUpChoice):
            AgentGuidanceMessage(
                title: "Do you want a follow-up too?",
                detail: "I can draft just the lead, or include a task if you know the next step.",
                systemImage: "bell.badge",
                options: [
                    AgentGuidanceOption(title: "Add a follow-up", subtitle: "I will ask for task and timing.", prompt: "Add a follow-up", systemImage: "calendar.badge.plus", tint: .green),
                    AgentGuidanceOption(title: "No follow-up", subtitle: "Draft contact, opportunity, and notes only.", prompt: "No follow-up", systemImage: "minus.circle", tint: .secondary)
                ]
            )
        case (.newLead, .leadFollowUpDetail):
            AgentGuidanceMessage(
                title: "What should the follow-up say?",
                detail: "Include the task and timing, for example: Send proposal Friday.",
                systemImage: "calendar"
            )
        case (.deleteContact, .targetContact):
            AgentConversationPlanner.contactQuestion(
                title: "Which contact should I delete?",
                detail: "I can only delete an existing local contact after review and confirmation.",
                snapshot: snapshot
            )
        case (.updateContact, .targetContact):
            AgentConversationPlanner.contactQuestion(
                title: "Which contact should I update?",
                detail: "Pick an existing contact first. Then I will ask what should change.",
                snapshot: snapshot
            )
        case (.updateContact, .updateDetail):
            AgentGuidanceMessage(
                title: "What should change for this contact?",
                detail: "For example: add email, update role, append a note, or change the phone number.",
                systemImage: "square.and.pencil"
            )
        case (.deleteOpportunity, .targetOpportunity):
            AgentConversationPlanner.opportunityQuestion(
                title: "Which opportunity should I delete?",
                detail: "I can only delete an existing local opportunity after review and confirmation.",
                opportunities: snapshot.opportunities
            )
        case (.deleteFollowUp, .targetFollowUp):
            AgentConversationPlanner.followUpQuestion(
                title: "Which follow-up should I delete?",
                detail: "I can only delete an existing local follow-up after review and confirmation.",
                followUps: snapshot.followUps
            )
        case (.completeFollowUp, .targetFollowUp):
            AgentConversationPlanner.followUpQuestion(
                title: "Which follow-up is done?",
                detail: "Pick an existing follow-up and I will prepare a review card.",
                followUps: snapshot.followUps
            )
        case (.createFollowUp, .targetContact):
            AgentConversationPlanner.contactQuestion(
                title: "Who is this follow-up for?",
                detail: "Choose an existing contact. If this is a new lead, create the lead first.",
                snapshot: snapshot
            )
        case (.createFollowUp, .followUpDetail):
            AgentGuidanceMessage(
                title: "What is the follow-up?",
                detail: "Include the task and timing, for example: Send concept next Tuesday.",
                systemImage: "calendar.badge.plus"
            )
        default:
            AgentConversationPlanner.genericRecoveryNotice()
        }
    }

    private func newLeadTranscript() -> String {
        let name = fields["contactName"] ?? ""
        let company = fields["company"] ?? ""
        let need = fields["need"] ?? ""
        let followUp = fields["followUp"]?.nilIfBlank

        var lines = [
            "New lead from guided chat.",
            "Contact: \(name)",
            "Company: \(company)",
            "Notes: \(need)",
            "Create a contact, create an opportunity from the notes, and add an interaction."
        ]

        if let followUp {
            lines.append("Create a follow-up: \(followUp)")
        }

        return lines.joined(separator: "\n")
    }
}

private enum AgentConversationPlanner {
    static func guidance(for text: String, snapshot: CRMDataSnapshot) -> AgentGuidedRoute {
        let key = text.searchKey
        let intent = AgentIntent(textKey: key)

        if snapshot.isEmpty && intent.requiresExistingData {
            return .notice(emptyCRMNotice())
        }

        switch intent {
        case .newLead:
            if shouldGuideNewLead(key: key) {
                let workflow = AgentGuidedWorkflow(kind: .newLead, step: .leadName)
                return .workflow(workflow, workflow.questionForCurrentStep(snapshot: snapshot))
            }
            return .none

        case .deleteContact:
            guard !snapshot.contacts.isEmpty else { return .notice(noContactsNotice()) }
            let matches = matchingContacts(text, snapshot: snapshot)
            if matches.count == 1, key.wordCount > 2 { return .none }
            let workflow = AgentGuidedWorkflow(kind: .deleteContact, step: .targetContact)
            return .workflow(workflow, workflow.questionForCurrentStep(snapshot: snapshot))

        case .deleteOpportunity:
            guard !snapshot.opportunities.isEmpty else { return .notice(noOpportunitiesNotice()) }
            let matches = matchingOpportunities(text, snapshot: snapshot)
            if matches.count == 1, key.wordCount > 2 { return .none }
            let workflow = AgentGuidedWorkflow(kind: .deleteOpportunity, step: .targetOpportunity)
            return .workflow(workflow, workflow.questionForCurrentStep(snapshot: snapshot))

        case .deleteFollowUp:
            guard !snapshot.followUps.isEmpty else { return .notice(noFollowUpsNotice()) }
            let matches = matchingFollowUps(text, snapshot: snapshot)
            if matches.count == 1, key.wordCount > 2 { return .none }
            let workflow = AgentGuidedWorkflow(kind: .deleteFollowUp, step: .targetFollowUp)
            return .workflow(workflow, workflow.questionForCurrentStep(snapshot: snapshot))

        case .completeFollowUp:
            guard !snapshot.followUps.isEmpty else { return .notice(noFollowUpsNotice()) }
            let matches = matchingFollowUps(text, snapshot: snapshot)
            if matches.count == 1, key.wordCount > 2 { return .none }
            let workflow = AgentGuidedWorkflow(kind: .completeFollowUp, step: .targetFollowUp)
            return .workflow(workflow, workflow.questionForCurrentStep(snapshot: snapshot))

        case .createFollowUp:
            guard !snapshot.contacts.isEmpty || !snapshot.opportunities.isEmpty else { return .notice(emptyCRMNotice()) }
            let matches = matchingContacts(text, snapshot: snapshot)
            if matches.count == 1, key.wordCount > 5 { return .none }
            let workflow = AgentGuidedWorkflow(kind: .createFollowUp, step: .targetContact)
            return .workflow(workflow, workflow.questionForCurrentStep(snapshot: snapshot))

        case .updateContact:
            guard !snapshot.contacts.isEmpty else { return .notice(noContactsNotice()) }
            let matches = matchingContacts(text, snapshot: snapshot)
            if matches.count == 1, key.wordCount > 4 { return .none }
            let workflow = AgentGuidedWorkflow(kind: .updateContact, step: .targetContact)
            return .workflow(workflow, workflow.questionForCurrentStep(snapshot: snapshot))

        case .unknown:
            if snapshot.isEmpty {
                return .notice(emptyCRMNotice())
            }
            return .none
        }
    }

    static func matchingContacts(_ text: String, snapshot: CRMDataSnapshot) -> [CRMContactSnapshot] {
        let key = text.searchKey
        guard !key.isEmpty else { return [] }
        return snapshot.contacts.filter { contact in
            key.matchesCRMName(contact.fullName) ||
                key.contains(contact.company.searchKey) ||
                (!contact.company.searchKey.isEmpty && contact.company.searchKey.contains(key))
        }
    }

    static func matchingOpportunities(_ text: String, snapshot: CRMDataSnapshot) -> [CRMOpportunitySnapshot] {
        let key = text.searchKey
        guard !key.isEmpty else { return [] }
        return snapshot.opportunities.filter { opportunity in
            key.matchesCRMName(opportunity.title) ||
                key.contains(opportunity.company.searchKey) ||
                (!opportunity.company.searchKey.isEmpty && opportunity.company.searchKey.contains(key))
        }
    }

    static func matchingFollowUps(_ text: String, snapshot: CRMDataSnapshot) -> [CRMFollowUpSnapshot] {
        let key = text.searchKey
        guard !key.isEmpty else { return [] }
        return snapshot.followUps.filter { followUp in
            key.matchesCRMName(followUp.title) ||
                followUp.title.searchKey.contains(key) ||
                followUp.notes.searchKey.contains(key)
        }
    }

    static func contactQuestion(title: String, detail: String, snapshot: CRMDataSnapshot) -> AgentGuidanceMessage {
        AgentGuidanceMessage(
            title: title,
            detail: detail,
            systemImage: "person.crop.circle",
            options: snapshot.contacts.prefix(6).map { contact in
                AgentGuidanceOption(
                    title: contact.fullName,
                    subtitle: contact.company.nilIfBlank ?? "No company",
                    prompt: contact.fullName,
                    systemImage: "person",
                    tint: .blue
                )
            }
        )
    }

    static func opportunityQuestion(title: String, detail: String, opportunities: [CRMOpportunitySnapshot]) -> AgentGuidanceMessage {
        AgentGuidanceMessage(
            title: title,
            detail: detail,
            systemImage: "chart.line.uptrend.xyaxis",
            options: opportunities.prefix(6).map { opportunity in
                AgentGuidanceOption(
                    title: opportunity.title,
                    subtitle: "\(opportunity.company) - \(OpportunityStage.from(opportunity.stage)?.title ?? opportunity.stage)",
                    prompt: opportunity.title,
                    systemImage: "chart.line.uptrend.xyaxis",
                    tint: .green
                )
            }
        )
    }

    static func followUpQuestion(title: String, detail: String, followUps: [CRMFollowUpSnapshot]) -> AgentGuidanceMessage {
        AgentGuidanceMessage(
            title: title,
            detail: detail,
            systemImage: "bell",
            options: followUps.prefix(6).map { followUp in
                AgentGuidanceOption(
                    title: followUp.title,
                    subtitle: followUp.dueDateText.nilIfBlank ?? FollowUpState(rawValue: followUp.state)?.title ?? followUp.state,
                    prompt: followUp.title,
                    systemImage: "bell",
                    tint: .orange
                )
            }
        )
    }

    static func genericRecoveryNotice() -> AgentGuidanceMessage {
        AgentGuidanceMessage(
            title: "I need to restart that step",
            detail: "Tell me the CRM action again, and I will ask for each missing detail.",
            systemImage: "arrow.clockwise",
            options: starterOptions()
        )
    }

    private static func emptyCRMNotice() -> AgentGuidanceMessage {
        AgentGuidanceMessage(
            title: "There is no local CRM data yet",
            detail: "I cannot update, complete, or delete records until they exist. Start with a new lead, paste call notes, or load demo data from Settings.",
            systemImage: "tray",
            options: starterOptions()
        )
    }

    private static func noContactsNotice() -> AgentGuidanceMessage {
        AgentGuidanceMessage(
            title: "There are no contacts to use yet",
            detail: "Create the contact first, then I can update or delete it through a reviewed draft.",
            systemImage: "person.crop.circle.badge.exclamationmark",
            options: starterOptions()
        )
    }

    private static func noOpportunitiesNotice() -> AgentGuidanceMessage {
        AgentGuidanceMessage(
            title: "There are no opportunities to use yet",
            detail: "Create an opportunity from a lead first, then I can update or delete it.",
            systemImage: "chart.line.uptrend.xyaxis",
            options: starterOptions()
        )
    }

    private static func noFollowUpsNotice() -> AgentGuidanceMessage {
        AgentGuidanceMessage(
            title: "There are no follow-ups to use yet",
            detail: "Create a follow-up first, then I can mark it done or delete it after review.",
            systemImage: "bell.slash",
            options: starterOptions()
        )
    }

    private static func starterOptions() -> [AgentGuidanceOption] {
        [
            AgentGuidanceOption(title: "I have a new lead", subtitle: "Guided contact and opportunity capture.", prompt: "I have a new lead", systemImage: "person.crop.circle.badge.plus", tint: .blue),
            AgentGuidanceOption(title: "Paste call notes", subtitle: "Turn notes into a reviewed CRM draft.", prompt: "I want to paste call notes", systemImage: "text.bubble", tint: .green),
            AgentGuidanceOption(title: "Create a follow-up", subtitle: "Use an existing contact when one exists.", prompt: "Create a follow-up", systemImage: "calendar.badge.plus", tint: .orange)
        ]
    }

    private static func shouldGuideNewLead(key: String) -> Bool {
        key == "i have a new lead" ||
            key == "new lead" ||
            key == "neuer lead" ||
            key == "ich habe einen neuen lead" ||
            (key.contains("new lead") && key.wordCount < 7) ||
            (key.contains("neuer lead") && key.wordCount < 7)
    }
}

private enum AgentIntent {
    case newLead
    case deleteContact
    case deleteOpportunity
    case deleteFollowUp
    case updateContact
    case createFollowUp
    case completeFollowUp
    case unknown

    init(textKey key: String) {
        let wantsDelete = key.contains("delete") || key.contains("remove") || key.contains("losche") || key.contains("loesche")
        let wantsContact = key.contains("contact") || key.contains("kontakt")
        let wantsOpportunity = key.contains("opportunity") || key.contains("opportunitat")
        let wantsFollowUp = key.contains("follow") || key.contains("task") || key.contains("aufgabe")

        if key.contains("new lead") || key.contains("neuer lead") || key.contains("new contact") || key.contains("neuer kontakt") || key.contains("ich habe einen neuen lead") {
            self = .newLead
        } else if wantsDelete && wantsContact {
            self = .deleteContact
        } else if wantsDelete && wantsOpportunity {
            self = .deleteOpportunity
        } else if wantsDelete && wantsFollowUp {
            self = .deleteFollowUp
        } else if key.contains("done") || key.contains("complete") || key.contains("erledigt") {
            self = .completeFollowUp
        } else if key.contains("create follow") || key.contains("new follow") || key.contains("remind") || key.contains("erinnere") {
            self = .createFollowUp
        } else if key.contains("update") || key.contains("edit") || key.contains("bearbeite") || key.contains("andere") || key.contains("aendere") {
            self = .updateContact
        } else {
            self = .unknown
        }
    }

    var requiresExistingData: Bool {
        switch self {
        case .deleteContact, .deleteOpportunity, .deleteFollowUp, .updateContact, .createFollowUp, .completeFollowUp:
            true
        case .newLead, .unknown:
            false
        }
    }
}

private extension CRMDataSnapshot {
    var isEmpty: Bool {
        contacts.isEmpty && opportunities.isEmpty && followUps.isEmpty
    }
}

private extension String {
    var wordCount: Int {
        split { $0.isWhitespace || $0.isNewline }.count
    }

    func matchesCRMName(_ value: String) -> Bool {
        let key = value.searchKey
        guard !key.isEmpty else { return false }
        if contains(key) || key.contains(self) {
            return true
        }

        return key
            .split(separator: " ")
            .contains { part in
                part.count > 2 && contains(part)
            }
    }
}
