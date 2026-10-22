import AppKit
import SwiftUI
import Dev2KitCore

/// Araç çubuğundaki İletişim düğmesi: Slack ve e-posta seçeneklerini gösteren
/// küçük pano.
///
/// Neden dairesel menüde değil: menü bir öğe seçilince kapanıp penceresini
/// gizliyor; panonun bağlanacağı düğme ortadan kalkardı. Geçmiş ve çarkla aynı
/// cam daire, her iki modda görünür.
///
/// Sistem panosu (popover) dışarı tıklanınca ve Escape ile kapanır, ekran
/// kenarına gelince yerini kendisi ayarlar. Bilgiler `ContactInfo.current`'tan.
struct ContactButton: View {
    var info = ContactInfo.current
    @State private var isOpen = false

    var body: some View {
        let style = RadialMenuStyle()
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: style.iconSize - 2, weight: .semibold))
                .frame(width: style.itemDiameter, height: style.itemDiameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(ToolbarGlassCircle())
        .help(L10n.t("contact.title"))
        .accessibilityLabel(L10n.t("contact.title"))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            ContactPopover(info: info)
        }
    }
}

/// Panonun içeriği: başlık, kişi adı, kısa açıklama, iletişim seçenekleri.
struct ContactPopover: View {
    let info: ContactInfo
    var crashReports = CrashReportCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("contact.title"))
                    .font(.headline)
                if let name = info.displayName {
                    Label(name, systemImage: "person.crop.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.purple)
                        .textSelection(.enabled)
                }
                Text(L10n.t("contact.description"))
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                ForEach(info.channels) { channel in
                    ContactChannelRow(channel: channel)
                }
            }
            Divider()
            CrashReportSection(center: crashReports)
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .onAppear { crashReports.refresh() }
    }
}

/// Tek seçenek: simge, ad, değer, aç ve kopyala. Kopyalanınca simge kısa
/// süre onay işaretine döner (ve VoiceOver'a duyurulur).
private struct ContactChannelRow: View {
    let channel: ContactChannel
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    /// Onay işaretinin görünme süresi.
    private static let feedbackDuration: Duration = .seconds(1.5)

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.purple)
                .frame(width: 28, height: 28)
                .background(Theme.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(copied ? L10n.t("contact.copied") : channel.value ?? "")
                    .font(.secondaryText)
                    .foregroundStyle(copied ? Theme.up : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(channel.value ?? "")
            }
            Spacer(minLength: 4)
            actionButton(symbol: "arrow.up.forward.square", help: openTitle) {
                if let url = channel.url { NSWorkspace.shared.open(url) }
            }
            actionButton(symbol: copied ? "checkmark" : "plus.square.on.square",
                         help: copied ? L10n.t("contact.copied") : L10n.t("contact.copy"),
                         tint: copied ? Theme.up : Theme.purple, action: copy)
        }
        .padding(8)
        .background(Theme.inputBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.inputBorder))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .onDisappear { resetTask?.cancel() }
    }

    private func copy() {
        guard let value = channel.value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        AccessibilityNotification.Announcement(L10n.t("contact.copied")).post()
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: Self.feedbackDuration)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private func actionButton(symbol: String, help: String, tint: Color = Theme.purple,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .iconHitTarget(24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .help(help)
        .accessibilityLabel(help)
    }

    private var icon: String {
        switch channel.kind {
        case .slack: "message"
        case .email: "envelope"
        }
    }

    private var title: String {
        switch channel.kind {
        case .slack: L10n.t("contact.slack")
        case .email: L10n.t("contact.email")
        }
    }

    private var openTitle: String {
        switch channel.kind {
        case .slack: L10n.t("contact.openSlack")
        case .email: L10n.t("contact.openEmail")
        }
    }
}
