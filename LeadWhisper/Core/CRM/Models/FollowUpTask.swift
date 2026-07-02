import Foundation
import SwiftData

@Model
final class FollowUpTask {
    @Attribute(.unique) var id: UUID
    var contactID: UUID?
    var opportunityID: UUID?
    var title: String
    var dueDate: Date?
    var dueDateText: String
    var notes: String
    var stateRaw: String
    var createdAt: Date
    var updatedAt: Date

    var state: FollowUpState {
        get { FollowUpState(rawValue: stateRaw) ?? .open }
        set { stateRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        contactID: UUID? = nil,
        opportunityID: UUID? = nil,
        title: String,
        dueDate: Date? = nil,
        dueDateText: String = "",
        notes: String = "",
        state: FollowUpState = .open,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.contactID = contactID
        self.opportunityID = opportunityID
        self.title = title
        self.dueDate = dueDate
        self.dueDateText = dueDateText
        self.notes = notes
        self.stateRaw = state.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
