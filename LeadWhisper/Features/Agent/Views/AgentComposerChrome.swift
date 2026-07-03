import BeamBorder
import SwiftUI

enum AgentBeamMode: Hashable {
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

struct AgentAvatar: View {
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

struct ProcessingBubble: View {
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

struct AgentPrivacyPopover: View {
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

struct SuggestedActionBar: View {
    let suggestions: [AgentSuggestion]
    let isEnabled: Bool
    let select: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { suggestion in
                    Button {
                        select(suggestion.prompt)
                    } label: {
                        Label {
                            Text(suggestion.title)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: suggestion.systemImage)
                                .font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(.blue.opacity(0.16))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                    .accessibilityLabel(suggestion.title)
                    .accessibilityHint(suggestion.subtitle ?? "")
                }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
    }
}

struct ClarificationActionBar: View {
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

struct DraftRevisionStatusBar: View {
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
