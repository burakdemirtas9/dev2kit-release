import AppKit
import Dev2KitCore

/// Uygulama menüsündeki "dev2kit Hakkında": sistemin standart Hakkında
/// penceresi (ikon, ad, sürüm) ve altında İletişim panosundaki bilgiler
/// (ad, Slack, e-posta). Bilgiler tek kaynaktan (`ContactInfo.current`);
/// panodaki "son çökme raporu" bölümü burada yok (kullanıcı isteği,
/// 2026-10-24).
enum AboutPanel {
    @MainActor
    static func show() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "dev2kit",
            .applicationVersion: Dev2KitIdentity.version,
            .credits: credits(),
        ]
        // `.app`'te derleme numarası Info.plist'te; bundle'sız çalışmada yok.
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            options[.version] = build
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate()
    }

    /// İletişim bilgileri; Slack ve e-posta tıklanabilir. Kullanılamayan
    /// (boş ya da geçersiz bağlantılı) seçenek panodaki gibi gösterilmez.
    static func credits(for info: ContactInfo = .current) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 3
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString()
        func line(_ string: String, _ extra: [NSAttributedString.Key: Any] = [:]) {
            if text.length > 0 { text.append(NSAttributedString(string: "\n", attributes: base)) }
            text.append(NSAttributedString(string: string, attributes: base.merging(extra) { $1 }))
        }

        line(L10n.t("contact.title"), [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)])
        line(L10n.t("contact.description"), [.foregroundColor: NSColor.secondaryLabelColor])
        if let name = info.displayName { line(name) }
        for channel in info.channels {
            guard let url = channel.url else { continue }
            switch channel.kind {
            case .slack:
                // Bağlantının kendisi uzun ve okunmaz; eylem adı gösterilir.
                line("\(L10n.t("contact.slack")): ")
                text.append(NSAttributedString(string: L10n.t("contact.openSlack"), attributes: base.merging([.link: url]) { $1 }))
            case .email:
                line("\(L10n.t("contact.email")): ")
                text.append(NSAttributedString(string: channel.value ?? "", attributes: base.merging([.link: url]) { $1 }))
            }
        }
        return text
    }
}
