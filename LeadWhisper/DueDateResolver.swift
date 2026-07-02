import Foundation

enum DueDateResolver {
    static func date(from text: String?, now: Date = .now, calendar: Calendar = .current) -> Date? {
        guard let text = text?.nilIfBlank else { return nil }
        let key = text.searchKey

        if key.contains("tomorrow") || key.contains("morgen") {
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        }

        let weekdays: [(names: [String], value: Int)] = [
            (["sunday", "sonntag"], 1),
            (["monday", "montag"], 2),
            (["tuesday", "dienstag"], 3),
            (["wednesday", "mittwoch"], 4),
            (["thursday", "donnerstag"], 5),
            (["friday", "freitag"], 6),
            (["saturday", "samstag"], 7)
        ]

        if let weekday = weekdays.first(where: { entry in
            entry.names.contains { key.contains($0) }
        })?.value {
            return next(weekday: weekday, from: now, calendar: calendar)
        }

        return nil
    }

    private static func next(weekday: Int, from date: Date, calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: date)
        let current = calendar.component(.weekday, from: start)
        var delta = weekday - current
        if delta <= 0 {
            delta += 7
        }
        return calendar.date(byAdding: .day, value: delta, to: start)
    }
}
