import Foundation
import Testing
@testable import LeadWhisper

@MainActor
struct DueDateResolverTests {
    @Test func dueDateResolverFindsNextWeekday() throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = 2026
        components.month = 7
        components.day = 2
        let thursday = try #require(components.date)

        let friday = try #require(DueDateResolver.date(from: "Friday", now: thursday, calendar: components.calendar!))
        #expect(components.calendar!.component(.weekday, from: friday) == 6)

        let nextTuesday = try #require(DueDateResolver.date(from: "next Tuesday", now: thursday, calendar: components.calendar!))
        #expect(components.calendar!.component(.weekday, from: nextTuesday) == 3)
    }
}
