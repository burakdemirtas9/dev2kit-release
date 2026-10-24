import AppKit
import SwiftUI
import Dev2KitCore

/// Contact panosunun altındaki "Son çökme raporu" bölümü.
///
/// Durumlar ayrı adlandırılır: macOS raporuyla doğrulanmış çökme, olası
/// temiz olmayan kapanış (çökme kanıtı değil), kayıt yok, rapor dizinine
/// erişilemedi. Ayrıntı metni sabit yükseklikte kayar; pano büyümez.
struct CrashReportSection: View {
    let center: CrashReportCenter
    @State private var showsDetails: Bool
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    init(center: CrashReportCenter, showsDetails: Bool = false) {
        self.center = center
        _showsDetails = State(initialValue: showsDetails)
    }

    /// Ayrıntı alanının en büyük yüksekliği.
    static let detailsHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("crash.title"))
                .font(.system(size: 12, weight: .semibold))
            content
        }
        .onDisappear { resetTask?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch center.state {
        case .checking:
            message(L10n.t("crash.checking"), icon: "hourglass")
        case .inactive:
            message(L10n.t("crash.none"), icon: "checkmark.circle")
        case .ready(let status):
            if let latest = status.latest {
                report(latest)
            } else if status.reportsAccessible {
                message(L10n.t("crash.none"), icon: "checkmark.circle")
            } else {
                message(L10n.t("crash.inaccessible"), icon: "questionmark.folder")
            }
        }
    }

    private func message(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.secondaryText)
            .foregroundStyle(.secondary)
    }

    private func report(_ record: LatestCrashRecord) -> some View {
        let verified = record.kind == .verifiedCrash
        let summary = record.summary
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // Doğrulanmış çökme hata, olası kapanış uyarı (TASARIM §4).
                Image(systemName: verified ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(verified ? Theme.down : Theme.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verified ? summary?.headline ?? "—" : L10n.t("crash.unclean.title"))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(metadataLine(record))
                        .font(.secondaryText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if !verified {
                Text(L10n.t(record.reportsAccessible ? "crash.unclean.note" : "crash.unclean.noteInaccessible"))
                    .font(.tinyText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsDetails, let text = center.reportText {
                ScrollView {
                    Text(text)
                        .font(.tinyMono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(height: Self.detailsHeight)
                .background(Theme.inputBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.inputBorder))
            }
            HStack(spacing: 12) {
                Button(L10n.t(showsDetails ? "crash.details.hide" : "crash.details.show")) { showsDetails.toggle() }
                Button(copied ? L10n.t("contact.copied") : L10n.t("crash.copy"), action: copy)
                    .foregroundStyle(copied ? Theme.up : Theme.purple)
                    .disabled(center.reportText == nil)
                Spacer()
                Button(L10n.t("crash.clear")) {
                    showsDetails = false
                    center.clear()
                }
                .foregroundStyle(.secondary)
                .help(L10n.t("crash.clear.help"))
            }
            .buttonStyle(.link)
            .font(.secondaryText)
        }
    }

    /// "21 Eki 22:28 · Sürüm 1.2 (177)"
    private func metadataLine(_ record: LatestCrashRecord) -> String {
        let date = record.summary?.crashedAt ?? record.session.launchedAt
        let version = L10n.t("crash.version", record.summary?.appVersion ?? record.session.appVersion,
                             record.summary?.build ?? record.session.build)
        return "\(L10n.date(date)) · \(version)"
    }

    private func copy() {
        guard let text = center.reportText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        AccessibilityNotification.Announcement(L10n.t("contact.copied")).post()
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
