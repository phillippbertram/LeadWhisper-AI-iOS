import Foundation
import SwiftData

@Model
final class FollowUpTask {
    #Index<FollowUpTask>([\.stateRaw], [\.dueDate])

    @Attribute(.unique) var id: UUID
    var title: String
    var dueDate: Date?
    var dueDateText: String
    var notes: String
    var stateRaw: String
    var createdAt: Date
    var updatedAt: Date

    var contact: Contact?
    var opportunity: Opportunity?

    var state: FollowUpState {
        get { FollowUpState(rawValue: stateRaw) ?? .open }
        set { stateRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        contact: Contact? = nil,
        opportunity: Opportunity? = nil,
        title: String,
        dueDate: Date? = nil,
        dueDateText: String = "",
        notes: String = "",
        state: FollowUpState = .open,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.dueDateText = dueDateText
        self.notes = notes
        self.stateRaw = state.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.contact = contact
        self.opportunity = opportunity
    }
}

extension FollowUpTask {
    /// Shared ordering for follow-up lists: due-dated tasks first in ascending
    /// order; tasks without a due date fall back to creation order.
    static func dueDateOrder(_ lhs: FollowUpTask, _ rhs: FollowUpTask) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case let (left?, right?):
            left < right
        case (_?, nil):
            true
        case (nil, _?):
            false
        case (nil, nil):
            lhs.createdAt < rhs.createdAt
        }
    }
}
