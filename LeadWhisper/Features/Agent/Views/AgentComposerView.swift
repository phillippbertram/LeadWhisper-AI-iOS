import FactoryKit
import OSLog
import SwiftUI

struct AgentComposerView: View {
    private enum Constants {
        static let bottomAnchor = "agent-bottom-anchor"
    }

    private enum EntryElement {
        case content
        case toolbar
        case inputBar
    }

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @AppStorage(AgentSettings.providerKindKey) private var selectedProviderRawValue = AgentProviderKind.appleFoundationModels.rawValue
    @FocusState private var isInputFocused: Bool
    @State private var voiceInput = VoiceInputService()
    @State private var engine = Container.shared.agentConversationEngine()
    @State private var draftText = ""
    @State private var activeTranscript = ""
    @State private var analyzeTask: Task<Void, Never>?
    @State private var messages: [AgentConversationMessage] = []
    @State private var suggestions: [AgentSuggestion] = []
    @State private var crmSnapshot = CRMDataSnapshot(contacts: [], opportunities: [], followUps: [])
    @State private var activeResultID: UUID?
    @State private var pendingDestructiveRun: PendingAgentSave?
    @State private var isProcessing = false
    @State private var showsPrivacyInfo = false
    @State private var actionError: PresentableError?
    @State private var hasShownEntryAnimation = false
    @State private var hasAppliedInitialPrompt = false
    private let initialPrompt: String?
    private let openChangedRecord: ((ChangedCRMRecord) -> Void)?

    init(initialPrompt: String? = nil, openChangedRecord: ((ChangedCRMRecord) -> Void)? = nil) {
        self.initialPrompt = initialPrompt
        self.openChangedRecord = openChangedRecord
    }

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
                            openChangedRecord: openChangedRecord,
                            save: saveDraft,
                            cancel: cancelDraft
                        )
                        .id(message.id)
                    }

                    if isProcessing {
                        ProcessingBubble(
                            activity: engine.currentActivity,
                            accessibilityReduceMotion: accessibilityReduceMotion
                        )
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
            .opacity(entryOpacity)
            .offset(y: entryOffset(for: .content))
            .animation(entryAnimation(delay: 0), value: hasShownEntryAnimation)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if activeReviewResult != nil {
                        DraftRevisionStatusBar(
                            isEnabled: !isProcessing,
                            cancel: cancelActiveDraft
                        )
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if !activeClarificationOptions.isEmpty {
                        ClarificationActionBar(
                            options: activeClarificationOptions,
                            isEnabled: !isProcessing,
                            select: submit
                        )
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if !activeSuggestedActions.isEmpty {
                        SuggestedActionBar(
                            suggestions: activeSuggestedActions,
                            isEnabled: !isProcessing,
                            select: submit
                        )
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    AgentInputBar(
                        text: $draftText,
                        isInputFocused: $isInputFocused,
                        placeholder: inputPlaceholder,
                        voicePhase: voiceInput.phase,
                        audioLevel: voiceInput.audioLevel,
                        canRecord: voiceInput.canRecordAudio,
                        statusMessage: voiceInput.statusMessage,
                        isProcessing: isProcessing,
                        accessibilityReduceMotion: accessibilityReduceMotion,
                        contextUsage: engine.contextWindowUsage,
                        contextEvent: engine.contextWindowEvent,
                        providerStatusMessage: providerStatusMessage,
                        send: { submitDraftText() },
                        voiceAction: handleVoiceAction
                    )
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black)
                .opacity(entryOpacity)
                .offset(y: entryOffset(for: .inputBar))
                .animation(entryAnimation(delay: 0.12), value: hasShownEntryAnimation)
                .animation(.snappy(duration: 0.18), value: activeClarificationOptions)
                .animation(.snappy(duration: 0.18), value: activeSuggestedActions.map(\.id))
                .animation(.snappy(duration: 0.18), value: activeResultID)
            }
            .onAppear {
                applyInitialPromptIfNeeded()
                refreshSuggestions()
                engine.refreshContextWindowUsage(for: draftText)
                scrollToBottom(proxy)
                showEntryAnimation()
            }
            .onChange(of: draftText) { _, newValue in
                engine.refreshContextWindowUsage(for: newValue, debounce: true)
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: isProcessing) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: selectedProviderRawValue) { _, _ in
                resetConversation()
            }
        }
        .background(Color.black.ignoresSafeArea())
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
                .opacity(entryOpacity)
                .offset(y: entryOffset(for: .toolbar))
                .animation(entryAnimation(delay: 0.07), value: hasShownEntryAnimation)
                .popover(isPresented: $showsPrivacyInfo) {
                    AgentPrivacyPopover(providerKind: selectedProviderKind, availabilityMessage: engine.availabilityMessage)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    resetConversation()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .disabled(!canResetConversation)
                .opacity(entryOpacity)
                .offset(y: entryOffset(for: .toolbar))
                .animation(entryAnimation(delay: 0.07), value: hasShownEntryAnimation)
            }
        }
        .task {
            engine.prewarm()
        }
        .onChange(of: voiceInput.phase) { oldValue, newValue in
            guard oldValue == .transcribing, newValue == .idle,
                  let transcript = voiceInput.transcript.nilIfBlank else { return }
            insertTranscript(transcript)
        }
        .onDisappear {
            resetEntryAnimation()
        }
    }

    private var canResetConversation: Bool {
        !messages.isEmpty ||
            !draftText.isEmpty ||
            isProcessing ||
            activeResultID != nil
    }

    private var selectedProviderKind: AgentProviderKind {
        AgentProviderKind(rawValue: selectedProviderRawValue) ?? .appleFoundationModels
    }

    private var providerStatusMessage: String {
        selectedProviderKind.modelStatusLabel
    }

    private var activeClarification: ClarificationPrompt? {
        guard let activeResultID else { return nil }
        return messages.compactMap { message -> ClarificationPrompt? in
            guard case .result(let runResult, _) = message.content,
                  runResult.id == activeResultID else {
                return nil
            }
            return runResult.draft.clarification
        }
        .first
    }

    private var activeClarificationOptions: [String] {
        guard let activeClarification else { return [] }

        var seenKeys = Set<String>()
        return activeClarification.options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.searchKey
            guard !trimmed.isEmpty,
                  !isFreeTextClarificationOption(key),
                  seenKeys.insert(key).inserted else {
                return nil
            }
            return trimmed
        }
    }

    private var inputPlaceholder: String {
        if activeReviewResult != nil {
            return "Tell me how to revise this draft..."
        }

        guard let activeClarification else {
            return "Tell me what changed with a lead..."
        }

        if let placeholder = activeClarification.placeholder?.nilIfBlank {
            return placeholder
        }
        if activeClarification.allowsFreeText == true {
            return "Type your answer..."
        }
        return "Tell me what changed with a lead..."
    }

    private var activeSuggestedActions: [AgentSuggestion] {
        guard !isProcessing,
              !messages.isEmpty,
              activeReviewResult == nil,
              activeClarification == nil,
              let lastMessage = messages.last else {
            return []
        }

        switch lastMessage.content {
        case .assistant:
            return AgentSuggestionBuilder.contextualSuggestions(from: crmSnapshot)
        case .followUpOverview:
            return AgentSuggestionBuilder.contextualSuggestions(from: crmSnapshot, prefersFollowUpActions: true)
        case .receipt(let changedRecords):
            return AgentSuggestionBuilder.receiptSuggestions(from: changedRecords)
        case .result(let runResult, _):
            guard runResult.errorMessage == nil else { return [] }
            return AgentSuggestionBuilder.contextualSuggestions(from: crmSnapshot)
        case .user:
            return []
        }
    }

    private var entryOpacity: Double {
        accessibilityReduceMotion || hasShownEntryAnimation ? 1 : 0
    }

    private func entryOffset(for element: EntryElement) -> CGFloat {
        guard !accessibilityReduceMotion, !hasShownEntryAnimation else { return 0 }

        switch element {
        case .content:
            return 6
        case .toolbar:
            return -2
        case .inputBar:
            return 10
        }
    }

    private func entryAnimation(delay: Double) -> Animation? {
        guard !accessibilityReduceMotion else { return nil }
        return .easeOut(duration: 0.24).delay(delay)
    }

    private func showEntryAnimation() {
        hasShownEntryAnimation = true
    }

    private func resetEntryAnimation() {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            hasShownEntryAnimation = false
        }
    }

    private func isFreeTextClarificationOption(_ key: String) -> Bool {
        let exactMatches = [
            "other",
            "something else",
            "not listed",
            "none of these",
            "none of the above",
            "type it",
            "type your answer",
            "write answer",
            "custom answer",
            "free text"
        ]
        if exactMatches.contains(key) {
            return true
        }

        return [
            "provide",
            "enter",
            "type",
            "write",
            "specify",
            "add detail",
            "add details",
            "fill in",
            "tell me",
            "share",
            "give"
        ].contains { prefix in
            key == prefix || key.hasPrefix("\(prefix) ")
        }
    }

    private var activeReviewResult: AgentRunResult? {
        guard let activeResultID else { return nil }
        return messages.compactMap { message -> AgentRunResult? in
            guard case .result(let runResult, _) = message.content,
                  runResult.id == activeResultID,
                  runResult.draft.canApply else {
                return nil
            }
            return runResult
        }
        .first
    }

    private func refreshSuggestions() {
        do {
            let snapshot = try Container.shared.crmRepository().snapshot()
            crmSnapshot = snapshot
            suggestions = AgentSuggestionBuilder.suggestions(from: snapshot)
        } catch {
            AppLog.agent.error("Agent suggestions snapshot failed error=\(error.localizedDescription, privacy: .public)")
            let emptySnapshot = CRMDataSnapshot(contacts: [], opportunities: [], followUps: [])
            crmSnapshot = emptySnapshot
            suggestions = AgentSuggestionBuilder.suggestions(from: emptySnapshot)
        }
    }

    private func applyInitialPromptIfNeeded() {
        guard !hasAppliedInitialPrompt,
              messages.isEmpty,
              draftText.nilIfBlank == nil,
              let initialPrompt = initialPrompt?.nilIfBlank else {
            return
        }

        draftText = initialPrompt
        hasAppliedInitialPrompt = true
    }

    private func submitDraftText() {
        submit(draftText)
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isProcessing else { return }
        let activeReview = activeReviewResult
        HapticFeedback.play(.lightImpact)

        if voiceInput.phase != .idle {
            voiceInput.cancelRecording()
        }

        draftText = ""
        dismissKeyboard()
        if activeReview == nil {
            activeResultID = nil
        }
        messages.append(.user(trimmed))
        activeTranscript = activeTranscript.isEmpty ? trimmed : "\(activeTranscript)\n\(trimmed)"

        let outboundMessage: String
        let replacedResultID: UUID?
        if let activeReview {
            outboundMessage = revisionPrompt(for: activeReview, instruction: trimmed)
            replacedResultID = activeReview.id
            activeResultID = nil
        } else {
            outboundMessage = trimmed
            replacedResultID = nil
        }

        analyzeTask?.cancel()
        analyzeTask = Task { await analyze(message: outboundMessage, replacingResultID: replacedResultID) }
    }

    private func analyze(message: String, replacingResultID: UUID? = nil) async {
        AppLog.agent.info("Agent analyze requested messageCharacters=\(message.count, privacy: .public)")
        isProcessing = true
        defer { isProcessing = false }

        var result = await engine.send(message)

        guard !Task.isCancelled else {
            AppLog.agent.info("Agent turn result discarded because the task was cancelled")
            return
        }

        if result.errorMessage != nil {
            HapticFeedback.play(.warning)
        }

        if !result.draft.proposedChanges.isEmpty {
            result.diffs = Container.shared.changeDiffBuilder().diffs(for: result.draft.proposedChanges)
        }

        if result.kind == .reply, result.errorMessage == nil {
            let text = result.message.nilIfBlank ?? "Tell me which contact, opportunity, or follow-up you want to change and what should happen next."
            activeResultID = replacingResultID
            if result.followUpOverviewItems.isEmpty {
                messages.append(.assistant(text, detail: nil, systemImage: "sparkles"))
            } else {
                messages.append(.followUpOverview(title: text, items: result.followUpOverviewItems))
            }
        } else {
            activeResultID = result.id
            if let replacingResultID,
               let index = messages.firstIndex(where: { $0.resultID == replacingResultID }) {
                messages.remove(at: index)
            }
            messages.append(.result(result, transcript: activeTranscript))
        }
        AppLog.agent.info("Agent analyze finished kind=\(result.kind.rawValue, privacy: .public) proposedChanges=\(result.draft.proposedChanges.count, privacy: .public) hasError=\(result.errorMessage == nil ? "false" : "true", privacy: .public)")
    }

    private func saveDraft(_ runResult: AgentRunResult, transcript: String, proposedChanges: [ProposedChange], selectedChangeIDs: Set<String>) {
        guard runResult.id == activeResultID else { return }

        var draft = runResult.draft
        draft.proposedChanges = proposedChanges.filter { selectedChangeIDs.contains($0.id) }
        guard !draft.proposedChanges.isEmpty else { return }

        if draft.containsDestructiveChange {
            HapticFeedback.play(.warning)
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
            refreshSuggestions()
            messages.append(.receipt(result.changedRecords))
            HapticFeedback.play(.success)
            AppLog.agent.info("Agent draft saved changedRecords=\(result.changedRecords.count, privacy: .public)")
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
        HapticFeedback.play(.selection)
        AppLog.agent.info("Agent draft cancelled")
    }

    private func cancelActiveDraft() {
        guard let activeReviewResult else { return }
        cancelDraft(activeReviewResult)
    }

    private func revisionPrompt(for result: AgentRunResult, instruction: String) -> String {
        """
        Revise the active review draft using this new user instruction. Return a fresh AgentTurn with the complete revised draft, not just the delta. Keep any proposed changes that are still correct and update, add, or remove only what the instruction changes.

        User revision instruction:
        \(instruction)

        Active draft summary:
        \(result.draft.summary)

        Active proposed changes:
        \(revisionChangeSummary(for: result.draft.proposedChanges))
        """
    }

    private func revisionChangeSummary(for changes: [ProposedChange]) -> String {
        guard !changes.isEmpty else { return "No proposed changes." }

        return changes.enumerated().map { index, change in
            let fields = [
                change.contactName.map { "contact=\($0)" },
                change.company.map { "company=\($0)" },
                change.opportunityTitle.map { "opportunity=\($0)" },
                change.stage.map { "stage=\($0)" },
                change.followUpTitle.map { "followUp=\($0)" },
                change.dueDateText.map { "due=\($0)" },
                change.notes.map { "notes=\($0)" }
            ]
            .compactMap { $0?.nilIfBlank }
            .joined(separator: "; ")

            return "\(index + 1). action=\(change.action.rawValue); title=\(change.title); targetID=\(change.targetID ?? "-"); \(fields)"
        }
        .joined(separator: "\n")
    }

    private func handleVoiceAction() {
        switch voiceInput.phase {
        case .idle:
            dismissKeyboard()
            Task {
                await voiceInput.startRecording()
                if voiceInput.isRecording {
                    HapticFeedback.play(.mediumImpact)
                }
            }
        case .recording:
            voiceInput.finishRecording()
            HapticFeedback.play(.lightImpact)
        case .starting:
            voiceInput.cancelRecording()
        case .transcribing:
            break
        }
    }

    private func insertTranscript(_ transcript: String) {
        if accessibilityReduceMotion {
            draftText = transcript
        } else {
            withAnimation(.smooth(duration: 0.35)) {
                draftText = transcript
            }
        }
        isInputFocused = true
    }

    private func resetConversation() {
        analyzeTask?.cancel()
        voiceInput.reset()
        engine.reset()
        draftText = ""
        activeTranscript = ""
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
