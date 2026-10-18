import Foundation

/// Zaman metinleri (JWT süreleri ve zaman damgası aracı ortak). Workbench
/// arayüzü İngilizce: biçimler sabit `en_US_POSIX`.
enum TimeText {
    static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// "2026-10-19 21:30:00 +03:00"
    static func local(_ date: Date, _ timeZone: TimeZone) -> String {
        formatter("yyyy-MM-dd HH:mm:ss xxx", timeZone).string(from: date)
    }

    /// "2026-10-19 18:30:00 UTC"
    static func utc(_ date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm:ss", TimeZone(identifier: "UTC")!).string(from: date) + " UTC"
    }

    /// "in 23 min", "2 h 5 min ago".
    static func relative(_ date: Date, now: Date) -> String {
        let delta = date.timeIntervalSince(now)
        let text = duration(abs(delta))
        if abs(delta) < 1 { return "now" }
        return delta > 0 ? "in \(text)" : "\(text) ago"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let days = total / 86_400, hours = total % 86_400 / 3_600, minutes = total % 3_600 / 60, secs = total % 60
        if days > 0 { return hours > 0 ? "\(days) d \(hours) h" : "\(days) d" }
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(secs) s"
    }
}
