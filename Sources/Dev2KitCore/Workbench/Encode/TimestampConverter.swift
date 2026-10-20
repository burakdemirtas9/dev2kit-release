import Foundation

/// Zaman damgası dönüştürücü (step 2a). Satır başına bir değer:
/// - Sayı: basamak sayısından birim (≤10 saniye, ≤13 milisaniye, ≤16
///   mikrosaniye, fazlası nanosaniye); ondalıklı saniye kabul edilir.
/// - Tarih: ISO 8601 (bölgeli/bölgesiz, kesirli), "yyyy-MM-dd HH:mm:ss",
///   "yyyy-MM-dd", HTTP tarihi (RFC 1123). Bölgesiz tarih YEREL saat sayılır.
/// - Boş girdi: şu an.
/// Çıktı: Unix saniye/milisaniye, ISO 8601 UTC, yerel (Mac'in saat dilimi)
/// ve UTC, göreli zaman (kullanıcı kararı: yerel + UTC yan yana).
public enum TimestampConverter {
    public static let maxLines = 100

    public static func convert(_ input: String, now: Date = Date(), timeZone: TimeZone = .current) throws -> String {
        let values = input.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if values.isEmpty { return describe(now, source: "now", now: now, timeZone: timeZone) }
        return try values.prefix(maxLines).map { value in
            let (date, unit) = try parse(value, timeZone: timeZone)
            return describe(date, source: "\(value) (\(unit))", now: now, timeZone: timeZone)
        }.joined(separator: "\n\n")
    }

    static func parse(_ value: String, timeZone: TimeZone) throws -> (Date, String) {
        if let number = Double(value), value.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) {
            let digits = value.split(separator: ".").first.map { $0.filter(\.isNumber).count } ?? 0
            let (seconds, unit): (Double, String)
            switch digits {
            case ...10: (seconds, unit) = (number, "seconds")
            case ...13: (seconds, unit) = (number / 1_000, "milliseconds")
            case ...16: (seconds, unit) = (number / 1_000_000, "microseconds")
            default: (seconds, unit) = (number / 1_000_000_000, "nanoseconds")
            }
            guard TimeText.isRepresentable(seconds) else {
                throw WorkbenchIssue(message: L10n.t("time.outOfRange", String(value.prefix(40))))
            }
            return (Date(timeIntervalSince1970: seconds), unit)
        }
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: value) { return (date, "ISO 8601") }
        }
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            if let date = TimeText.formatter(format, timeZone).date(from: value) { return (date, "local time") }
        }
        if let date = TimeText.formatter("EEE, dd MMM yyyy HH:mm:ss zzz", TimeZone(identifier: "GMT")!).date(from: value) {
            return (date, "HTTP date")
        }
        throw WorkbenchIssue(message: L10n.t("time.unknown", value))
    }

    private static func describe(_ date: Date, source: String, now: Date, timeZone: TimeZone) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = date.timeIntervalSince1970
        let weekday = TimeText.formatter("EEEE", timeZone).string(from: date)
        let rows: [(String, String)] = [
            ("Input", source),
            ("Unix (s)", String(Int64(seconds.rounded(.down)))),
            ("Unix (ms)", String(Int64((seconds * 1_000).rounded(.down)))),
            ("ISO 8601", iso.string(from: date)),
            ("Local", "\(TimeText.local(date, timeZone)) \(timeZone.identifier) (\(weekday))"),
            ("UTC", TimeText.utc(date)),
            ("Relative", TimeText.relative(date, now: now)),
        ]
        return rows.map { "\($0.0.padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.1)" }.joined(separator: "\n")
    }
}
