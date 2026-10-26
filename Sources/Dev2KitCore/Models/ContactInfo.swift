import Foundation

/// İletişim panosundaki bilgiler (araç çubuğu → İletişim).
///
/// Tek merkezi yapılandırma: gerçek Slack ve e-posta bilgileri yalnızca
/// `ContactInfo.current` içine yazılır; pano, bağlantı ve kopyalama
/// aksiyonları buradan türetilir. Boş ya da geçersiz bir seçenek panoda hiç
/// gösterilmez (`channels`): yarım bilgiyle bağlantı açılmaz.
public struct ContactInfo: Equatable, Sendable {
    /// Panoda başlığın altında görünen kişi adı.
    public var name: String?
    /// Slack'te görünen ad (ör. kanal adı).
    public var slackLabel: String?
    /// Slack bağlantısı; yalnızca `https`, protokolsüz yazılırsa `https://`.
    public var slackLink: String?
    /// E-posta adresi; bağlantısı `mailto:` olarak türetilir.
    public var email: String?

    public init(name: String? = nil, slackLabel: String? = nil, slackLink: String? = nil, email: String? = nil) {
        self.name = name
        self.slackLabel = slackLabel
        self.slackLink = slackLink
        self.email = email
    }

    /// Uygulamada gösterilen bilgiler (kullanıcı isteği, 2026-10-22).
    /// Değişince yalnızca burası güncellenir.
    public static let current = ContactInfo(
        name: "Burak Demirtaş",
        slackLink: "https://getirfinans.slack.com/app_redirect?channel=D0AQVG31007",
        email: "burak.demirtas@getirfinans.com"
    )

    /// Görünen ad; boşsa `nil`.
    public var displayName: String? { Self.trimmed(name) }

    /// Ad yoksa bağlantının kendisi (protokol eklenmiş hali) görünür ve kopyalanır.
    public var slack: ContactChannel {
        let url = Self.slackURL(slackLink)
        return ContactChannel(kind: .slack, value: Self.trimmed(slackLabel) ?? url?.absoluteString, url: url)
    }
    public var mail: ContactChannel { ContactChannel(kind: .email, value: email, url: Self.mailURL(email)) }
    /// Panoda gösterilecek seçenekler: yalnızca kullanılabilir olanlar.
    public var channels: [ContactChannel] { [slack, mail].filter(\.isAvailable) }

    /// Yalnızca ana makinesi olan `https` bağlantısı açılır: yapılandırmaya
    /// yanlışlıkla `file:` ya da özel şema yazılırsa tıklama onu çalıştırmasın.
    /// Protokol yoksa `https://` eklenir ("chat.example.test/x").
    static func slackURL(_ link: String?) -> URL? {
        guard var link = trimmed(link) else { return nil }
        if !link.contains("://") { link = "https://" + link }
        guard let components = URLComponents(string: link),
              components.scheme?.lowercased() == "https", components.host?.isEmpty == false,
              let url = components.url else { return nil }
        return url
    }

    /// Tek `@`, iki yanı dolu, boşluk ve `mailto` parametresi (`?`, `&`,
    /// `%`) yok: adres konu/gövde ya da ek alıcı taşıyamaz.
    static func mailURL(_ address: String?) -> URL? {
        guard let address = trimmed(address) else { return nil }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "?&%/:<>\"\\,;"))
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              address.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        return components.url
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// Panodaki bir iletişim seçeneği.
public struct ContactChannel: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case slack, email }

    public let kind: Kind
    /// Görünen ve kopyalanan metin; yoksa yer tutucu gösterilir.
    public let value: String?
    /// Açılacak bağlantı; geçerli değilse `nil`.
    public let url: URL?

    public var id: Kind { kind }

    /// Seçenek etkin mi: hem gösterilecek değer hem geçerli bağlantı var.
    /// Biri eksikse yarım bilgiyle bağlantı açılmaz, kopyalanmaz.
    public var isAvailable: Bool { url != nil && value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }

    public init(kind: Kind, value: String?, url: URL?) {
        self.kind = kind
        self.value = value
        self.url = url
    }
}
