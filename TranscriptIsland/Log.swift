import Foundation
import os

extension Logger {
    /// A logger under the app's bundle ID. To follow the app's logs:
    /// `log stream --predicate 'subsystem == "<bundle id>"'`
    static func app(_ category: String) -> Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "TranscriptIsland", category: category)
    }
}
