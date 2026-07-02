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
    @State private var hasShownEntryAnimation = false
    private let openChangedRecord: ((ChangedCRMRecord) -> Void)?

    init(openChangedRecord: ((ChangedCRMRecord) -> Void)? = nil) {
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
                        isRecording: voiceInput.isRecording,
                        canRecord: voiceInput.canRecordAudio,
                        statusMessage: voiceInput.statusMessage,
                        isProcessing: isProcessing,
                        accessibilityReduceMotion: accessibilityReduceMotion,
                        contextUsage: engine.contextWindowUsage,
                        contextEvent: engine.contextWindowEvent,
                        providerStatusMessage: providerStatusMessage,
                        send: { submitDraftText() },
                        toggleRecording: toggleRecording
                    )
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 10)
                .background(.ultraThinMaterial)
                .opacity(entryOpacity)
                .offset(y: entryOffset(for: .inputBar))
                .animation(entryAnimation(delay: 0.12), value: hasShownEntryAnimation)
                .animation(.snappy(duration: 0.18), value: activeClarificationOptions)
                .animation(.snappy(duration: 0.18), value: activeResultID)
            }
            .onAppear {
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
        .onChange(of: voiceInput.transcript) { _, newValue in
            guard isVoiceSession else { return }
            draftText = newValue
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

    private func submitDraftText() {
        submit(draftText)
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isProcessing else { return }
        let activeReview = activeReviewResult

        if voiceInput.isRecording {
            voiceInput.stopRecording()
        }

        draftText = ""
        dismissKeyboard()
        isVoiceSession = false
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

        if !result.draft.proposedChanges.isEmpty {
            result.diffs = Container.shared.changeDiffBuilder().diffs(for: result.draft.proposedChanges)
        }

        if result.kind == .reply, result.errorMessage == nil {
            let text = result.message.nilIfBlank ?? "Tell me which contact, opportunity, or follow-up you want to change and what should happen next."
            activeResultID = replacingResultID
            messages.append(.assistant(text, detail: nil, systemImage: "sparkles"))
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
            messages.append(.receipt(result.changedRecords))
            speechOutput.speak(result.spokenSummary)
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
    case user(String)
    case result(AgentRunResult, transcript: String)
    case receipt([ChangedCRMRecord])
}

private struct AgentMessageRow: View {
    let message: AgentConversationMessage
    let activeResultID: UUID?
    let openChangedRecord: ((ChangedCRMRecord) -> Void)?
    let save: (AgentRunResult, String, Set<String>) -> Void
    let cancel: (AgentRunResult) -> Void

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
                cancel: cancel
            )

        case .receipt(let changedRecords):
            ReceiptBubble(changedRecords: changedRecords, open: openChangedRecord)
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(systemImage: avatarImage)
            AgentResultView(
                runResult: runResult,
                showsActions: isActive,
                save: { selectedChangeIDs in save(runResult, transcript, selectedChangeIDs) },
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
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 36)
        }
    }
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

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AgentAvatar(systemImage: "brain")
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(friendlyActivity)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TypingDots()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityLabel("LeadWhisper is thinking")
            .accessibilityValue(friendlyActivity)
            Spacer(minLength: 36)
        }
    }

    private var friendlyActivity: String {
        guard let activity = activity?.nilIfBlank else {
            return "Preparing a review draft..."
        }

        if activity.hasPrefix("findContacts") {
            return "Checking matching contacts..."
        }
        if activity.hasPrefix("findOpportunities") {
            return "Checking pipeline..."
        }
        if activity.hasPrefix("findFollowUps") {
            return "Checking follow-ups..."
        }
        if activity.hasPrefix("getPipelineSummary") {
            return "Reading your CRM summary..."
        }
        return "Preparing a review draft..."
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
            "Everything runs on this device. Proposed changes are only saved after you review them."
        case .openAI:
            "Agent messages and local CRM lookup results are sent to OpenAI. Proposed changes are still only saved after you review them."
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
    let isRecording: Bool
    let canRecord: Bool
    let statusMessage: String
    let isProcessing: Bool
    let accessibilityReduceMotion: Bool
    let contextUsage: AgentContextWindowUsage
    let contextEvent: AgentContextWindowEvent?
    let providerStatusMessage: String
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
            TextField(placeholder, text: $text, axis: .vertical)
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
                    tint: isRecording ? .red : canRecord ? .blue : .secondary,
                    isEnabled: canRecord || isRecording,
                    accessibilityLabel: isRecording ? "Stop recording" : canRecord ? "Start recording" : "Voice input unavailable",
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
                if let contextEvent {
                    ContextWindowEventChip(event: contextEvent)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .layoutPriority(2)
                }
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
        .animation(.snappy(duration: 0.18), value: contextEvent?.id)
    }

    private var statusLine: String {
        if isRecording {
            return "Listening..."
        }
        guard let statusMessage = statusMessage.nilIfBlank,
              statusMessage != VoiceInputService.temporarilyDisabledMessage else {
            return providerStatusMessage
        }
        return "\(providerStatusMessage) - \(statusMessage)"
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
