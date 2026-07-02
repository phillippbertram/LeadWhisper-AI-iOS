enum FollowUpState: String, CaseIterable, Codable, Identifiable {
    case open
    case done
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open:
            "Open"
        case .done:
            "Done"
        case .archived:
            "Archived"
        }
    }
}
