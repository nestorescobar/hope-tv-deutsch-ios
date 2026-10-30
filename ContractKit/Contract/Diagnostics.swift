import Foundation
import Observation

/// In-app telemetry. The research is explicit that rejections and fallbacks must be
/// observable rather than silent, so every acceptance decision lands here and is
/// visible on the Diagnostics screen.
@Observable
final class Diagnostics {
    enum Level: String {
        case info, warn, reject, ok
    }

    struct Entry: Identifiable {
        let id = UUID()
        let at = Date()
        let level: Level
        let title: String
        let detail: String?
    }

    private(set) var entries: [Entry] = []

    /// Counters the research asks for: rejection reason, fallback count, active revision.
    private(set) var rejectionCount = 0
    private(set) var fallbackCount = 0
    private(set) var fetchCount = 0
    private(set) var notModifiedCount = 0

    func log(_ level: Level, _ title: String, _ detail: String? = nil) {
        #if DEBUG
        // The device log, so a simulator run can be read with `log stream`.
        NSLog("[tv] %@: %@ — %@", level.rawValue, title, detail ?? "")
        #endif
        entries.insert(Entry(level: level, title: title, detail: detail), at: 0)
        if entries.count > 120 { entries.removeLast(entries.count - 120) }
        switch level {
        case .reject: rejectionCount += 1
        case .warn: fallbackCount += 1
        default: break
        }
    }

    func countFetch() { fetchCount += 1 }
    func countNotModified() { notModifiedCount += 1 }
    func clear() { entries.removeAll() }
}
