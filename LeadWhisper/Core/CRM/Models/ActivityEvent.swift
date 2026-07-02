import Foundation
import SwiftData

@Model
final class ActivityEvent {
    #Index<ActivityEvent>([\.createdAt])

    @Attribute(.unique) var id: UUID
    var title: String
    var detail: String
    @Attribute(originalName: "entityKind") var entityKindRaw: String
    var entityID: UUID?
    var createdAt: Date

    var entityKind: ActivityEntityKind {
        get { ActivityEntityKind(rawValue: entityKindRaw) ?? .system }
        set { entityKindRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String,
        detail: String = "",
        entityKind: ActivityEntityKind = .system,
        entityID: UUID? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.entityKindRaw = entityKind.rawValue
        self.entityID = entityID
        self.createdAt = createdAt
    }
}
