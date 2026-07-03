import BeamBorder
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
                            startPrompt: submit,
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
                    if !activeClarificationOptions.isEmpty {
                        ClarificationActionBar(
                            options: activeClarificationOptions,
                            isEnabled: !isProcessing,
                            select: submit
                        )
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if activeReviewResult != nil {
                        DraftRevisionStatusBar(
                            isEnabled: !isProcessing,
                            cancel: cancelActiveDraft
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
            suggestions = AgentSuggestionBuilder.suggestions(from: snapshot)
        } catch {
            AppLog.agent.error("Agent suggestions snapshot failed error=\(error.localizedDescription, privacy: .public)")
            suggestions = AgentSuggestionBuilder.suggestions(from: CRMDataSnapshot(contacts: [], opportunities: [], followUps: []))
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

private struct AgentConversationMessage: Identifiable {
    let id = UUID()
    var content: AgentMessageContent

    static func user(_ text: String) -> AgentConversationMessage {
        AgentConversationMessage(content: .user(text))
    }

    static func assistant(_ title: String, detail: String?, systemImage: String) -> AgentConversationMessage {
        AgentConversationMessage(content: .assistant(title: title, detail: detail, systemImage: systemImage))
    }

    static func followUpOverview(title: String, items: [AgentFollowUpOverviewItem]) -> AgentConversationMessage {
        AgentConversationMessage(content: .followUpOverview(title: title, items: items))
    }

    static func result(_ runResult: AgentRunResult, transcript: String) -> AgentConversationMessage {
        AgentConversationMessage(content: .result(runResult, transcript: transcript))
    }

    static func receipt(_ changedRecords: [ChangedCRMRecord]) -> AgentConversationMessage {
        AgentConversationMessage(content: .receipt(changedRecords))
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
    case followUpOverview(title: String, items: [AgentFollowUpOverviewItem])
    case user(String)
    case result(AgentRunResult, transcript: String)
    case receipt([ChangedCRMRecord])
}

private struct AgentMessageRow: View {
    let message: AgentConversationMessage
    let activeResultID: UUID?
    let openChangedRecord: ((ChangedCRMRecord) -> Void)?
    let startPrompt: (String) -> Void
    let save: (AgentRunResult, String, [ProposedChange], Set<String>) -> Void
    let cancel: (AgentRunResult) -> Void

    var body: some View {
        switch message.content {
        case .assistant(let title, let detail, let systemImage):
            AssistantBubble(title: title, detail: detail, systemImage: systemImage)

        case .followUpOverview(let title, let items):
            FollowUpOverviewBubble(title: title, items: items, open: openChangedRecord)

        case .user(let text):
            UserBubble(text: text)

        case .result(let runResult, let transcript):
            AgentResultBubble(
                runResult: runResult,
                transcript: transcript,
                isActive: runResult.id == activeResultID,
                save: save,
                cancel: cancel
            )

        case .receipt(let changedRecords):
            ReceiptBubble(changedRecords: changedRecords, open: openChangedRecord, startPrompt: startPrompt)
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

private struct FollowUpOverviewBubble: View {
    let title: String
    let items: [AgentFollowUpOverviewItem]
    let open: ((ChangedCRMRecord) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(systemImage: "calendar.badge.clock")
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        FollowUpOverviewRow(item: item, open: open)
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 36)
        }
    }
}

private struct FollowUpOverviewRow: View {
    let item: AgentFollowUpOverviewItem
    let open: ((ChangedCRMRecord) -> Void)?

    var body: some View {
        if let open {
            Button {
                open(item.changedRecord)
            } label: {
                rowContent(showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Follow-up, \(item.title), due \(item.dueDateText)")
        } else {
            rowContent(showsChevron: false)
        }
    }

    private var relatedText: String? {
        let values = [item.contactTitle, item.opportunityTitle]
            .compactMap { $0?.nilIfBlank }
        return values.isEmpty ? nil : values.joined(separator: " / ")
    }

    private func rowContent(showsChevron: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.badge")
                .font(.headline)
                .foregroundStyle(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Label(item.dueDateText, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if let relatedText {
                    Label(relatedText, systemImage: "person.text.rectangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.14))
        }
    }
}

private struct UserBubble: View {
    let text: String
    @State private var isExpanded = false

    private var shouldCollapse: Bool {
        text.count > 260 || text.filter { $0 == "\n" }.count >= 5
    }

    var body: some View {
        HStack {
            Spacer(minLength: 46)
            VStack(alignment: .trailing, spacing: 7) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(shouldCollapse && !isExpanded ? 6 : nil)
                    .fixedSize(horizontal: false, vertical: true)

                if shouldCollapse {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Label(isExpanded ? "Hide" : "Show full note", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.86))
                }
            }
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
    let save: (AgentRunResult, String, [ProposedChange], Set<String>) -> Void
    let cancel: (AgentRunResult) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(systemImage: avatarImage)
            AgentResultView(
                runResult: runResult,
                showsActions: isActive,
                save: { proposedChanges, selectedChangeIDs in save(runResult, transcript, proposedChanges, selectedChangeIDs) },
                cancel: { cancel(runResult) }
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
    let changedRecords: [ChangedCRMRecord]
    let open: ((ChangedCRMRecord) -> Void)?
    let startPrompt: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(systemImage: "checkmark.seal.fill")
            VStack(alignment: .leading, spacing: 8) {
                Text("Saved to your CRM")
                    .font(.subheadline.weight(.semibold))
                if !changedRecords.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(changedRecords) { record in
                            ReceiptRecordRow(record: record, open: open)
                        }
                    }
                }
                if !nextPrompts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(nextPrompts) { prompt in
                            Button {
                                startPrompt(prompt.prompt)
                            } label: {
                                Label(prompt.title, systemImage: prompt.systemImage)
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 36)
        }
    }

    private var nextPrompts: [ReceiptPromptAction] {
        var actions: [ReceiptPromptAction] = []
        if let record = changedRecords.first(where: { $0.kind == .contact && $0.canOpen }) {
            actions.append(ReceiptPromptAction(
                title: "Add follow-up",
                systemImage: "bell.badge",
                prompt: "Create a follow-up for \(record.title)"
            ))
        } else if let record = changedRecords.first(where: { $0.kind == .opportunity && $0.canOpen }) {
            actions.append(ReceiptPromptAction(
                title: "Add follow-up",
                systemImage: "bell.badge",
                prompt: "Create a follow-up for the opportunity \(record.title)"
            ))
        }

        if let record = changedRecords.first(where: { $0.kind == .opportunity && $0.canOpen }) {
            actions.append(ReceiptPromptAction(
                title: "Mark proposal sent",
                systemImage: "paperplane",
                prompt: "Move the opportunity \(record.title) to proposal sent"
            ))
        }

        actions.append(ReceiptPromptAction(
            title: "What's due next?",
            systemImage: "calendar.badge.clock",
            prompt: "What is due next in my pipeline?"
        ))
        return Array(actions.prefix(3))
    }
}

private struct ReceiptPromptAction: Identifiable {
    let id = UUID()
    var title: String
    var systemImage: String
    var prompt: String
}

private struct ReceiptRecordRow: View {
    let record: ChangedCRMRecord
    let open: ((ChangedCRMRecord) -> Void)?

    var body: some View {
        if let open, record.canOpen, record.kind.isOpenableFromAgentReceipt {
            Button {
                open(record)
            } label: {
                rowContent(actionTitle: record.kind.openActionTitle, showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(record.kind.openActionTitle), \(record.title)")
        } else {
            rowContent(actionTitle: record.canOpen ? record.kind.receiptTitle : "Deleted from CRM", showsChevron: false)
        }
    }

    private func rowContent(actionTitle: String, showsChevron: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: record.kind.systemImage)
                .font(.caption)
                .foregroundStyle(.green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(actionTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, 3)
    }
}

private enum AgentBeamMode: Hashable {
    case idle
    case recording
    case processing

    var isActive: Bool {
        switch self {
        case .idle:
            false
        case .recording, .processing:
            true
        }
    }

    var reducedMotionBorder: Color {
        switch self {
        case .idle:
            .blue.opacity(0.42)
        case .recording:
            .red.opacity(0.48)
        case .processing:
            .cyan.opacity(0.44)
        }
    }

    var overlayBorder: Color {
        switch self {
        case .idle:
            .blue.opacity(0.16)
        case .recording:
            .red.opacity(0.34)
        case .processing:
            .cyan.opacity(0.26)
        }
    }

    var inputConfiguration: BeamBorderConfiguration {
        BeamBorderConfiguration(
            border: inputBorder,
            showsBaseBorder: true,
            beamColors: inputBeamColors,
            beamDirection: .both,
            beamBlur: inputBeamBlur,
            cornerRadius: 24,
            borderLineWidth: inputBorderLineWidth,
            baseBorderLineWidth: 0.8,
            animationDuration: inputAnimationDuration
        )
    }

    var avatarConfiguration: BeamBorderConfiguration {
        BeamBorderConfiguration(
            border: .blue.opacity(0.38),
            showsBaseBorder: true,
            beamColors: [.cyan.opacity(0.9), .blue.opacity(0.78), .green.opacity(0.82)],
            beamDirection: .both,
            beamBlur: 7,
            cornerRadius: 17,
            borderLineWidth: 0.65,
            baseBorderLineWidth: 0.6,
            animationDuration: 3.6
        )
    }

    private var inputBorder: Color {
        switch self {
        case .idle:
            .blue.opacity(0.72)
        case .recording:
            .red.opacity(0.9)
        case .processing:
            .blue.opacity(0.95)
        }
    }

    private var inputBeamColors: [Color] {
        switch self {
        case .idle, .processing:
            [.cyan, .blue, .green]
        case .recording:
            [.pink.opacity(0.96), .red.opacity(0.92), .orange.opacity(0.9)]
        }
    }

    private var inputBeamBlur: CGFloat {
        switch self {
        case .idle:
            12
        case .recording:
            16
        case .processing:
            18
        }
    }

    private var inputBorderLineWidth: CGFloat {
        switch self {
        case .idle:
            0.7
        case .recording, .processing:
            1.0
        }
    }

    private var inputAnimationDuration: Double {
        switch self {
        case .idle:
            3.2
        case .recording:
            2.4
        case .processing:
            1.8
        }
    }
}

private struct AgentAvatar: View {
    let systemImage: String
    var isWorking = false
    var accessibilityReduceMotion = false

    private var beamConfiguration: BeamBorderConfiguration {
        AgentBeamMode.processing.avatarConfiguration
    }

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
            .padding(isWorking ? 2 : 0)
            .overlay {
                if isWorking && accessibilityReduceMotion {
                    Circle()
                        .stroke(AgentBeamMode.processing.reducedMotionBorder, lineWidth: 1)
                        .padding(1)
                }
            }
            .beamBorder(beamConfiguration, isEnabled: isWorking && !accessibilityReduceMotion)
    }
}

private extension ActivityEntityKind {
    var isOpenableFromAgentReceipt: Bool {
        switch self {
        case .contact, .opportunity, .followUp:
            true
        case .interaction, .system:
            false
        }
    }

    var openActionTitle: String {
        switch self {
        case .contact:
            "Open Contact"
        case .opportunity:
            "Open Opportunity"
        case .followUp:
            "Open Follow-up"
        case .interaction:
            "Activity saved"
        case .system:
            "Saved"
        }
    }

    var receiptTitle: String {
        switch self {
        case .contact:
            "Contact saved"
        case .opportunity:
            "Opportunity saved"
        case .followUp:
            "Follow-up saved"
        case .interaction:
            "Activity saved"
        case .system:
            "Saved"
        }
    }
}

private struct ProcessingBubble: View {
    var activity: String?
    let accessibilityReduceMotion: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AgentAvatar(
                systemImage: "brain",
                isWorking: true,
                accessibilityReduceMotion: accessibilityReduceMotion
            )
            .beamBorder(AgentBeamMode.processing.avatarConfiguration, isEnabled: !accessibilityReduceMotion)
            Text(friendlyActivity)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.blue.opacity(0.12), lineWidth: 0.7)
                }
            Spacer(minLength: 36)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("LeadWhisper is working")
        .accessibilityValue(friendlyActivity)
    }

    private var friendlyActivity: String {
        guard let activity = activity?.nilIfBlank else {
            return "Working on it"
        }

        if activity.hasPrefix("findContacts") {
            return "Checking contacts"
        }
        if activity.hasPrefix("findOpportunities") {
            return "Checking pipeline"
        }
        if activity.hasPrefix("findFollowUps") {
            return "Checking follow-ups"
        }
        if activity.hasPrefix("getContactDetails") {
            return "Reading contact context"
        }
        if activity.hasPrefix("getPipelineSummary") {
            return "Reading CRM summary"
        }
        return "Working on it"
    }
}

private struct AgentPrivacyPopover: View {
    let providerKind: AgentProviderKind
    let availabilityMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: providerKind.privacySystemImage)
                .font(.subheadline.weight(.semibold))
            Text(availabilityMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: 300, alignment: .leading)
        .presentationCompactAdaptation(.popover)
    }

    private var title: String {
        switch providerKind {
        case .appleFoundationModels:
            "Private CRM agent"
        case .openAI:
            "Cloud CRM agent"
        }
    }

    private var detail: String {
        switch providerKind {
        case .appleFoundationModels:
            "Agent reasoning runs on this device. Voice dictation uses Apple Speech when you use the mic. Proposed changes are only saved after you review them."
        case .openAI:
            "Agent messages and local CRM lookup results are sent to OpenAI. Voice dictation uses Apple Speech when you use the mic. Proposed changes are still only saved after you review them."
        }
    }
}

private struct ClarificationActionBar: View {
    let options: [String]
    let isEnabled: Bool
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button {
                    select(option)
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: iconName(for: option))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 22)

                        Text(option)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 8)

                        Image(systemName: "arrow.up.message")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.blue.opacity(0.16))
                    }
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityLabel("Answer \(option)")
            }
        }
    }

    private func iconName(for option: String) -> String {
        let key = option.searchKey
        if key.contains("yes") || key.contains("no") || key.contains("unclear") {
            return "checkmark.circle"
        }
        if key.contains("follow") || key.contains("task") {
            return "bell"
        }
        if key.contains("opportunity") || key.contains("proposal") {
            return "chart.line.uptrend.xyaxis"
        }
        return "person.crop.circle"
    }
}

private struct DraftRevisionStatusBar: View {
    let isEnabled: Bool
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("Editing proposed draft", systemImage: "slider.horizontal.3")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.blue)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            Button {
                cancel()
            } label: {
                Label("Cancel draft", systemImage: "xmark.circle")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!isEnabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.blue.opacity(0.16))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AgentInputBar: View {
    @Binding var text: String
    let isInputFocused: FocusState<Bool>.Binding
    let placeholder: String
    let voicePhase: VoiceInputPhase
    let audioLevel: Float
    let canRecord: Bool
    let statusMessage: String
    let isProcessing: Bool
    let accessibilityReduceMotion: Bool
    let contextUsage: AgentContextWindowUsage
    let contextEvent: AgentContextWindowEvent?
    let providerStatusMessage: String
    let send: () -> Void
    let voiceAction: () -> Void

    @State private var revealBlur: CGFloat = 0

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        hasText && !isProcessing
    }

    private var isVoiceActive: Bool {
        voicePhase != .idle
    }

    private var beamMode: AgentBeamMode {
        if isProcessing {
            return .processing
        }
        switch voicePhase {
        case .starting, .recording:
            return .recording
        case .transcribing:
            return .processing
        case .idle:
            return .idle
        }
    }

    private var beamConfiguration: BeamBorderConfiguration {
        beamMode.inputConfiguration
    }

    private var staticBorderColor: Color {
        if accessibilityReduceMotion {
            return beamMode.reducedMotionBorder
        }
        return beamMode.overlayBorder
    }

    private var actionState: ComposerActionState {
        switch voicePhase {
        case .starting, .recording:
            return .stop
        case .transcribing:
            return .progress
        case .idle:
            if hasText {
                return .send
            }
            return canRecord ? .mic : .micUnavailable
        }
    }

    private var actionIsEnabled: Bool {
        switch actionState {
        case .mic, .stop:
            true
        case .send:
            canSend
        case .micUnavailable, .progress:
            false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            inputSurface

            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: isProcessing ? "brain" : isVoiceActive ? "waveform" : "lock.shield")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isProcessing || isVoiceActive ? .white : .secondary)
                    Text(statusLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
                .padding(.leading, 2)

                Spacer(minLength: 0)
                if let contextEvent {
                    ContextWindowEventChip(event: contextEvent)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .layoutPriority(2)
                }
                ContextWindowUsageRing(usage: contextUsage)
                ComposerActionButton(
                    state: actionState,
                    isEnabled: actionIsEnabled,
                    accessibilityReduceMotion: accessibilityReduceMotion,
                    action: actionState == .send ? send : voiceAction
                )
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(staticBorderColor, lineWidth: accessibilityReduceMotion ? 1.2 : 0.7)
        }
        .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 8)
        .beamBorder(beamConfiguration, isEnabled: beamMode.isActive && !accessibilityReduceMotion)
        .id(beamMode)
        .animation(.snappy(duration: 0.18), value: contextEvent?.id)
        .animation(stateAnimation(.smooth(duration: 0.3)), value: voicePhase)
        .animation(stateAnimation(.snappy(duration: 0.2)), value: hasText)
        .onChange(of: voicePhase) { oldValue, newValue in
            guard oldValue == .transcribing, newValue == .idle, !accessibilityReduceMotion else { return }
            revealBlur = 5
            withAnimation(.easeOut(duration: 0.45)) {
                revealBlur = 0
            }
        }
    }

    @ViewBuilder
    private var inputSurface: some View {
        ZStack(alignment: .leading) {
            if isVoiceActive {
                VoiceRecordingSurface(
                    phase: voicePhase,
                    audioLevel: audioLevel,
                    reduceMotion: accessibilityReduceMotion
                )
                .transition(surfaceTransition)
            } else {
                TextField(placeholder, text: $text, axis: .vertical)
                    .focused(isInputFocused)
                    .font(.body)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .blur(radius: revealBlur)
                    .transition(surfaceTransition)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var surfaceTransition: AnyTransition {
        accessibilityReduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98))
    }

    private func stateAnimation(_ animation: Animation) -> Animation? {
        accessibilityReduceMotion ? nil : animation
    }

    private var statusLine: String {
        switch voicePhase {
        case .starting, .recording:
            return "Listening..."
        case .transcribing:
            return "Transcribing..."
        case .idle:
            guard let statusMessage = statusMessage.nilIfBlank else {
                return providerStatusMessage
            }
            return "\(providerStatusMessage) - \(statusMessage)"
        }
    }
}

private enum ComposerActionState: Equatable {
    case mic
    case micUnavailable
    case send
    case stop
    case progress
}

/// The single trailing composer button that morphs between mic, send, stop,
/// and transcription-progress states.
private struct ComposerActionButton: View {
    let state: ComposerActionState
    let isEnabled: Bool
    let accessibilityReduceMotion: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(fillColor)
                if state == .progress {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.blue)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                } else {
                    Image(systemName: systemImage)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(isEnabled ? tint : .secondary)
                        .contentTransition(accessibilityReduceMotion ? .opacity : .symbolEffect(.replace))
                        .transition(.opacity)
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var systemImage: String {
        switch state {
        case .mic:
            "mic.fill"
        case .micUnavailable:
            "mic.slash.fill"
        case .send:
            "arrow.up"
        case .stop:
            "stop.fill"
        case .progress:
            "waveform"
        }
    }

    private var tint: Color {
        switch state {
        case .mic, .send, .progress:
            .blue
        case .micUnavailable:
            .secondary
        case .stop:
            .red
        }
    }

    private var fillColor: Color {
        if state == .progress {
            return Color.blue.opacity(0.14)
        }
        return isEnabled ? tint.opacity(0.14) : Color(.tertiarySystemFill)
    }

    private var accessibilityLabel: String {
        switch state {
        case .mic:
            "Start recording"
        case .micUnavailable:
            "Voice input unavailable"
        case .send:
            "Send to LeadWhisper"
        case .stop:
            "Stop recording and transcribe"
        case .progress:
            "Transcribing"
        }
    }
}

/// Replaces the text field while voice input is active: a live level-driven
/// waveform during recording, dimmed with a pulsing label while transcribing.
private struct VoiceRecordingSurface: View {
    let phase: VoiceInputPhase
    let audioLevel: Float
    let reduceMotion: Bool

    @State private var levelHistory: [Float] = Array(repeating: 0, count: 42)

    private var isTranscribing: Bool {
        phase == .transcribing
    }

    var body: some View {
        ZStack {
            if reduceMotion {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isTranscribing ? Color.secondary : .red)
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            } else {
                waveform
                    .opacity(isTranscribing ? 0.3 : 1)
                if isTranscribing {
                    Text("Transcribing...")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .phaseAnimator([0.45, 1.0]) { view, opacity in
                            view.opacity(opacity)
                        } animation: { _ in
                            .easeInOut(duration: 0.7)
                        }
                        .transition(.opacity)
                }
            }
        }
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .onChange(of: audioLevel) { _, newValue in
            guard !isTranscribing else { return }
            levelHistory.removeFirst()
            levelHistory.append(newValue)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        isTranscribing ? "Transcribing..." : "Listening..."
    }

    private var waveform: some View {
        HStack(spacing: 3) {
            ForEach(Array(levelHistory.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(isTranscribing ? Color.secondary : Color.blue)
                    .frame(width: 3, height: barHeight(for: level))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.linear(duration: 0.1), value: levelHistory)
    }

    private func barHeight(for level: Float) -> CGFloat {
        3 + 21 * CGFloat(min(max(level, 0), 1))
    }
}

private struct ContextWindowEventChip: View {
    let event: AgentContextWindowEvent

    private var tint: Color {
        switch event.kind {
        case .condensed:
            .orange
        case .refreshed:
            .blue
        }
    }

    var body: some View {
        Label {
            Text(event.title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        } icon: {
            Image(systemName: event.systemImage)
                .font(.caption2.weight(.bold))
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12), in: Capsule())
        .accessibilityLabel("Context window event")
        .accessibilityValue(event.accessibilityValue)
        .help(event.detail)
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
        .accessibilityLabel("Context window usage")
        .accessibilityValue(usage.accessibilityValue)
        .help("Context: \(usage.usedTokens)/\(usage.maximumTokens) tokens, \(usage.availableTokens) available")
    }
}
