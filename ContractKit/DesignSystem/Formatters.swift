import Foundation

enum DurationFormatter {
    static func short(seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "\(total)s"
    }
}

enum RelativeDateFormatter {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func from(_ date: Date?, relativeTo reference: Date = Date()) -> String? {
        guard let date else { return nil }
        return formatter.localizedString(for: date, relativeTo: reference)
    }
}

enum TimeOfDayFormatter {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static func string(from date: Date?) -> String? {
        guard let date else { return nil }
        return formatter.string(from: date)
    }
}
