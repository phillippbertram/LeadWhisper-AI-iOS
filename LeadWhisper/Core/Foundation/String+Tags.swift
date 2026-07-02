import Foundation

extension String {
    nonisolated func tagsFromCommaSeparatedText() -> [String] {
        split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
