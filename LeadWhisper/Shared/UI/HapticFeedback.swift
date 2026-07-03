import UIKit

enum HapticFeedbackStyle {
    case selection
    case lightImpact
    case mediumImpact
    case success
    case warning
    case error
}

@MainActor
enum HapticFeedback {
    static func play(_ style: HapticFeedbackStyle) {
        switch style {
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .lightImpact:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .mediumImpact:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
