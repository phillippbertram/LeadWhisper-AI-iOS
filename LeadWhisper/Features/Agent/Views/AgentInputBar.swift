import BeamBorder
import SwiftUI

struct AgentInputBar: View {
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
