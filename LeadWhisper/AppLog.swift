import Foundation
import OSLog

enum AppLog {
    nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "io.phillipp.LeadWhisper"

    nonisolated static let app = Logger(subsystem: subsystem, category: "app")
    nonisolated static let voice = Logger(subsystem: subsystem, category: "voice")
    nonisolated static let agent = Logger(subsystem: subsystem, category: "agent")
    nonisolated static let tools = Logger(subsystem: subsystem, category: "agent.tools")
    nonisolated static let data = Logger(subsystem: subsystem, category: "data")
    nonisolated static let executor = Logger(subsystem: subsystem, category: "executor")
}
