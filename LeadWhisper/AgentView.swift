import BeamBorder
import OSLog
import SwiftData
import SwiftUI

struct AgentView: View {
    var body: some View {
        NavigationStack {
            AgentComposerView(showTitle: false)
                .navigationTitle("Agent")
        }
    }
}

struct AgentComposerView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.modelContext) private var modelContext
    @State private var voiceInput = VoiceInputService()
    @State private var agentService = LeadAgentService()
    @State private var speechOutput = SpeechOutputService()
    @State private var manualTranscript = ""
    @State private var runResult: AgentRunResult?
    @State private var isProcessing = false
    @State private var statusMessage: String?

    var showTitle = true

    private var currentTranscript: String {
        if !voiceInput.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return voiceInput.transcript
        }
        return manualTranscript
    }

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
                voiceInput.reset()
                manualTranscript = ""
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
                get: { currentTranscript },
                set: { newValue in
                    manualTranscript = newValue
                    if !voiceInput.transcript.isEmpty {
                        voiceInput.transcript = newValue
                    }
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
                Task {
                    await analyze()
                }
            } label: {
                Label("Prepare Changes", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
        }
    }

    private func analyze() async {
        let transcript = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }

        AppLog.agent.info("Agent analyze requested transcriptCharacters=\(transcript.count, privacy: .public)")
        isProcessing = true
        statusMessage = nil
        defer { isProcessing = false }

        let repository = CRMRepository(context: modelContext)
        runResult = await agentService.draft(for: transcript, repository: repository)
        AppLog.agent.info("Agent analyze finished mockParser=\(runResult?.usedMockParser ?? false, privacy: .public) proposedChanges=\(runResult?.draft.proposedChanges.count ?? 0, privacy: .public)")
    }

    private func saveDraft() {
        guard let draft = runResult?.draft else { return }
        do {
            let repository = CRMRepository(context: modelContext)
            let result = try ChangeExecutor(repository: repository).apply(draft, transcript: currentTranscript)
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
        let transcript = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedTranscript = transcript.isEmpty ? answer : "\(transcript)\n\(answer)"

        manualTranscript = updatedTranscript
        if !voiceInput.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            voiceInput.transcript = updatedTranscript
        }
        runResult = nil
        statusMessage = nil

        Task {
            await analyze()
        }
    }

    private func loadSample() {
        manualTranscript = "New contact: Sarah Klein from BluePeak. She needs help with a Flutter app in August. Budget around 20,000 Euro. Create an opportunity, set it to Qualified, and remind me on Friday to send a proposal."
        voiceInput.transcript = ""
        runResult = nil
        statusMessage = nil
        AppLog.agent.debug("Agent sample transcript loaded")
    }
}

private struct AgentResultView: View {
    let runResult: AgentRunResult
    let save: () -> Void
    let cancel: () -> Void
    let answerClarification: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if runResult.usedMockParser {
                Label("Demo parser fallback", systemImage: "switch.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AgentTimelineView(items: runResult.timeline)
            DetectedFactsView(facts: runResult.draft.detectedFacts)

            if let clarification = runResult.draft.clarification {
                ClarificationView(clarification: clarification, select: answerClarification)

                Button(role: .cancel, action: cancel) {
                    Label("Cancel Draft", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                ProposedChangesView(changes: runResult.draft.proposedChanges)

                HStack(spacing: 12) {
                    Button(role: .cancel, action: cancel) {
                        Label("Cancel", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: save) {
                        Label("Save Changes", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!runResult.draft.canApply)
                }
            }
        }
    }
}

private struct AgentTimelineView: View {
    let items: [AgentTimelineItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent Plan")
                .font(.headline)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.systemImage)
                        .foregroundStyle(.blue)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                        Text(item.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DetectedFactsView: View {
    let facts: [DetectedFact]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Detected Facts")
                .font(.headline)
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: fact.kind))
                        .foregroundStyle(.green)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.value)
                            .font(.subheadline.weight(.semibold))
                        Text(fact.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "contact":
            "person"
        case "company":
            "building.2"
        case "opportunity":
            "chart.line.uptrend.xyaxis"
        case "budget":
            "eurosign.circle"
        case "stage":
            "flag"
        case "followUp":
            "bell"
        default:
            "note.text"
        }
    }
}

private struct ProposedChangesView: View {
    let changes: [ProposedChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Proposed Changes")
                .font(.headline)
            ForEach(changes) { change in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(change.title, systemImage: icon(for: change.action))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(change.action)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        if let contactName = change.contactName?.nilIfBlank {
                            LabeledContent("Contact", value: contactName)
                        }
                        if let company = change.company?.nilIfBlank {
                            LabeledContent("Company", value: company)
                        }
                        if let opportunityTitle = change.opportunityTitle?.nilIfBlank {
                            LabeledContent("Opportunity", value: opportunityTitle)
                        }
                        if let stage = change.stage.flatMap(OpportunityStage.from) {
                            LabeledContent("Stage", value: stage.title)
                        }
                        if let value = change.estimatedValueEUR {
                            LabeledContent("Value", value: value.formatted(.currency(code: "EUR").precision(.fractionLength(0))))
                        } else if let budget = change.budgetText?.nilIfBlank {
                            LabeledContent("Budget", value: budget)
                        }
                        if let dueDate = change.dueDateText?.nilIfBlank {
                            LabeledContent("Due", value: dueDate)
                        }
                        if let notes = change.notes?.nilIfBlank {
                            Text(notes)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        TagStrip(tags: change.tags)
                    }
                    .font(.footnote)
                }
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary)
                }
            }
        }
    }

    private func icon(for action: String) -> String {
        switch action {
        case "createContact", "updateContact":
            "person.crop.circle.badge.plus"
        case "createOpportunity", "updateOpportunityStage":
            "chart.line.uptrend.xyaxis"
        case "createFollowUp", "updateFollowUp", "archiveFollowUps":
            "bell"
        default:
            "text.bubble"
        }
    }
}

private struct ClarificationView: View {
    let clarification: ClarificationPrompt
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Clarification Needed", systemImage: "questionmark.circle")
                .font(.headline)
            Text(clarification.question)
                .font(.body)
            ForEach(clarification.options, id: \.self) { option in
                Button {
                    select(option)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.title3)
                        Text(option)
                            .font(.headline)
                            .lineLimit(2)
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
