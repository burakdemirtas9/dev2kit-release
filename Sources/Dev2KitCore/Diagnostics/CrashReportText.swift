import Foundation

/// Panoda gösterilen ve "Raporu Kopyala" ile kopyalanan tanılama metni.
///
/// Yalnızca `CrashSummary`'nin izin listesindeki alanlar ve günlükteki olay
/// türleri/hata kodları girer; ekrandaki metin ile kopyalanan aynıdır.
/// Doğrulanmamış kapanış "çökme raporu" diye adlandırılmaz.
public enum CrashReportText {
    public static func make(_ record: LatestCrashRecord, events: [DiagnosticEvent], current: SessionRecord) -> String {
        var lines: [String] = []
        switch record.kind {
        case .verifiedCrash: lines.append(L10n.t("crash.text.verifiedTitle"))
        case .uncleanShutdown:
            lines.append(L10n.t("crash.text.uncleanTitle"))
            lines.append(L10n.t(record.reportsAccessible ? "crash.unclean.note" : "crash.unclean.noteInaccessible"))
        }
        lines.append("")
        let summary = record.summary
        lines.append(L10n.t("crash.text.time", L10n.date(summary?.crashedAt ?? record.session.launchedAt)))
        if summary?.crashedAt == nil { lines.append(L10n.t("crash.text.sessionStart", L10n.date(record.session.launchedAt))) }
        lines.append(L10n.t("crash.text.version", summary?.appVersion ?? record.session.appVersion, summary?.build ?? record.session.build))
        lines.append(L10n.t("crash.text.os", summary?.osVersion ?? record.session.osVersion))
        if let summary {
            lines.append(L10n.t("crash.text.exception", summary.headline))
            if let subtype = summary.exceptionSubtype { lines.append(L10n.t("crash.text.subtype", subtype)) }
            if let termination = summary.termination { lines.append(L10n.t("crash.text.termination", termination)) }
            lines.append(L10n.t("crash.text.file", summary.fileName))
            if !summary.frames.isEmpty {
                lines.append("")
                lines.append(L10n.t("crash.text.frames"))
                lines += summary.frames.enumerated().map { "\($0.offset)  \($0.element)" }
            }
        }
        lines.append("")
        lines.append(L10n.t("crash.text.currentVersion", current.appVersion, current.build, current.osVersion))
        if !events.isEmpty {
            lines.append("")
            lines.append(L10n.t("crash.text.events"))
            lines += events.map(describe)
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ event: DiagnosticEvent) -> String {
        var parts = [ISO8601DateFormatter().string(from: event.time), event.kind.rawValue]
        if let detail = event.detail { parts.append(detail.rawValue) }
        if let domain = event.errorDomain { parts.append("\(domain) \(event.errorCode.map(String.init) ?? "")".trimmingCharacters(in: .whitespaces)) }
        return parts.joined(separator: "  ")
    }
}
