import Foundation

/// "Bu host'a uyan profil yok ama şu profil ona benziyor" önerisi.
///
/// Neden var: aynı iç servis çoğu zaman birden çok adla geliyor
/// (`api.firma.com` dışarıdan, `api.firma.local` içeriden). Kullanıcı
/// profili elle çoğaltmak zorunda kalmasın.
///
/// Neden ÖNERİ, otomatik genişletme değil: host kalıbı yalnızca hangi CA'nın
/// geçerli olduğunu değil, **istemci sertifikasının kime sunulacağını** da
/// belirler (bkz. `HostPattern`). `.local` ise RFC 6762 gereği sahipsizdir —
/// aynı ağdaki herhangi bir cihaz o adı iddia edebilir. Kalıbı sessizce
/// genişletmek, kurum kimliğini saldırganın kaptığı bir ada sunmak olurdu.
/// Bu yüzden karar kullanıcınındır ve kabul edilirse profile YAZILIR, yani
/// denetlenebilir kalır.
///
/// Kural bilinçli olarak dar: yalnızca kurum etiketi birebir eşitse öneri
/// çıkar. Yanlış bir öneri kullanıcıyı yanlış yere güvenmeye ikna edebilir,
/// bu yüzden "yakın benziyor" gibi bulanık bir ölçüt yok.
public enum TLSPatternSuggestion {
    public struct Match: Equatable, Sendable {
        public let profileID: UUID
        public let profileName: String
        /// Profile eklenmesi önerilen TAM host. Asla joker: kullanıcı isterse
        /// profil ekranından kendisi genişletir.
        public let hostToAdd: String
        /// Öneriyi doğuran kalıp; kullanıcıya "neye benzediği" gösterilir.
        public let matchedPattern: String
        /// Profil kimlik taşıyor mu. Taşıyorsa arayüz tek tık eklemez,
        /// profil düzenleyicisini açar: kullanıcı neyi onayladığını görsün.
        public let carriesClientCertificate: Bool
        /// Sonek genel değil mi (`.local` gibi). Uyarı metni buna göre değişir.
        public let isNonPublicSuffix: Bool

        public init(
            profileID: UUID,
            profileName: String,
            hostToAdd: String,
            matchedPattern: String,
            carriesClientCertificate: Bool,
            isNonPublicSuffix: Bool
        ) {
            self.profileID = profileID
            self.profileName = profileName
            self.hostToAdd = hostToAdd
            self.matchedPattern = matchedPattern
            self.carriesClientCertificate = carriesClientCertificate
            self.isNonPublicSuffix = isNonPublicSuffix
        }
    }

    /// Kayıtlı olmayan, yerel ağda iddia edilebilen sonekler.
    static let nonPublicSuffixes: Set<String> = [
        "local", "internal", "lan", "home", "corp", "intranet", "localdomain", "test",
    ]

    /// Kurum etiketi sayılmayacak genel sözcükler. `api.dev.local` ile
    /// `*.dev.com` arasında "dev" üzerinden bağ kurmak anlamsız.
    static let genericLabels: Set<String> = [
        "dev", "test", "api", "www", "app", "apps", "staging", "stage",
        "prod", "uat", "qa", "demo", "local", "internal", "home", "lan", "srv",
    ]

    /// İkinci seviye genel sonekler: `firma.com.tr`'de kurum etiketi "com"
    /// değil "firma"dır. Tam bir Public Suffix List taşımak bağımlılık
    /// demek; en yaygın olanlar yeterli, çünkü sonuç yalnızca bir ÖNERİ.
    static let publicSecondLevelLabels: Set<String> = [
        "com", "net", "org", "edu", "gov", "mil", "co", "ac", "gob", "or", "ne", "biz", "info",
    ]

    /// Çok kısa etiketler tesadüfen eşleşir.
    static let minimumLabelLength = 3

    /// Host için öneri. Host'a uyan bir profil zaten varsa öneri çıkmaz.
    public static func suggestion(for host: String, in profiles: [TLSProfile]) -> Match? {
        let host = normalize(host)
        guard !host.isEmpty else { return nil }
        // Zaten eşleşen profil varsa ortada bir sorun yok.
        guard TLSProfile.profile(for: host, in: profiles) == nil else { return nil }
        guard let organization = organizationLabel(of: host) else { return nil }

        for profile in profiles {
            for pattern in profile.hostPatterns where HostPattern.isValid(pattern) {
                let bare = normalize(pattern).hasPrefix("*.")
                    ? String(normalize(pattern).dropFirst(2))
                    : normalize(pattern)
                guard organizationLabel(of: bare) == organization else { continue }
                return Match(
                    profileID: profile.id,
                    profileName: profile.name,
                    hostToAdd: host,
                    matchedPattern: pattern.trimmingCharacters(in: .whitespaces),
                    carriesClientCertificate: profile.hasClientCertificate,
                    isNonPublicSuffix: isNonPublicSuffix(host)
                )
            }
        }
        return nil
    }

    public static func isNonPublicSuffix(_ host: String) -> Bool {
        guard let last = normalize(host).split(separator: ".").last else { return false }
        return nonPublicSuffixes.contains(String(last))
    }

    // MARK: - Yardımcılar

    private static func normalize(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces).lowercased()
        while text.hasSuffix(".") { text.removeLast() }   // kök nokta
        return text
    }

    /// Host'un kurum etiketi. Belirlenemiyorsa `nil` — öneri de çıkmaz.
    ///
    /// IP adresleri, tek etiketli adlar (`localhost`), çok kısa ve genel
    /// etiketler elenir.
    static func organizationLabel(of host: String) -> String? {
        let host = normalize(host)
        guard !host.isEmpty, !isIPAddress(host) else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }

        var index = labels.count - 2
        // `firma.com.tr`: bir seviye daha sola kay.
        if publicSecondLevelLabels.contains(labels[index]) {
            guard index >= 1 else { return nil }
            index -= 1
        }
        let label = labels[index]
        guard label.count >= minimumLabelLength, !genericLabels.contains(label) else { return nil }
        return label
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }   // IPv6
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }
}
