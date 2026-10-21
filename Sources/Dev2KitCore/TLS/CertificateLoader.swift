import Foundation
import Security

/// Diskteki sertifika dosyalarını Security framework nesnelerine çevirir.
public enum CertificateLoader {
    public struct LoadError: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    // MARK: - CA sertifikası

    /// PEM ya da DER kodlu sertifika dosyasını okur.
    /// PEM dosyası birden çok sertifika içerebilir (zincir); hepsi döner.
    public static func loadCertificates(atPath path: String) throws -> [SecCertificate] {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw LoadError(message: L10n.t("cert.notFound", path))
        }
        guard let data = FileManager.default.contents(atPath: expanded) else {
            throw LoadError(message: L10n.t("cert.unreadable", path))
        }

        let blocks = pemBlocks(in: data)
        let sources = blocks.isEmpty ? [data] : blocks
        let certificates = sources.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }

        guard !certificates.isEmpty else {
            throw LoadError(message: L10n.t("cert.invalid"))
        }
        return certificates
    }

    /// PEM metnindeki `-----BEGIN CERTIFICATE-----` bloklarını DER'e çevirir.
    /// Dosya DER ise boş dizi döner ve çağıran ham veriyi kullanır.
    static func pemBlocks(in data: Data) -> [Data] {
        guard let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") else {
            return []
        }
        var blocks: [Data] = []
        var current: [String]?
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-----BEGIN") && trimmed.contains("CERTIFICATE") {
                current = []
            } else if trimmed.hasPrefix("-----END") && trimmed.contains("CERTIFICATE") {
                if let body = current?.joined(),
                   let decoded = Data(base64Encoded: body, options: .ignoreUnknownCharacters) {
                    blocks.append(decoded)
                }
                current = nil
            } else if current != nil, !trimmed.isEmpty {
                current?.append(trimmed)
            }
        }
        return blocks
    }

    // MARK: - İstemci kimliği

    /// PKCS#12 dosyasından istemci kimliğini (sertifika + özel anahtar) çıkarır.
    ///
    /// `SecPKCS12Import` macOS'ta varsayılan olarak kimliği kullanıcının
    /// varsayılan (login) keychain'ine KALICI ekler (SDK belgesi). Eskiden
    /// burada "anahtar diske kopyalanmaz" yazıyordu ama her yüklemede özel
    /// anahtar login keychain'e yazılıyordu (güvenlik incelemesi, 2026-10-21).
    /// macOS 15+: `kSecImportToMemoryOnly` ile yalnızca süreç belleğinde.
    /// macOS 14'te bu seçenek yok; eski davranış sürer (bilinen sınır).
    public static func loadIdentity(atPath path: String, password: String) throws -> SecIdentity {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw LoadError(message: L10n.t("cert.client.notFound", path))
        }
        guard let data = FileManager.default.contents(atPath: expanded) else {
            throw LoadError(message: L10n.t("cert.client.unreadable", path))
        }

        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)

        switch status {
        case errSecSuccess:
            break
        case errSecAuthFailed:
            throw LoadError(message: L10n.t("cert.client.password"))
        case errSecDecode:
            throw LoadError(message: L10n.t("cert.client.decode"))
        default:
            throw LoadError(message: L10n.t("cert.client.status", String(status)))
        }

        guard let entries = items as? [[String: Any]],
              let first = entries.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            throw LoadError(message: L10n.t("cert.client.noIdentity"))
        }
        // SecIdentity CFTypeRef olarak gelir; tip güvenli dönüşüm.
        guard CFGetTypeID(identityRef as CFTypeRef) == SecIdentityGetTypeID() else {
            throw LoadError(message: L10n.t("cert.client.notIdentity"))
        }
        return unsafeBitCast(identityRef as CFTypeRef, to: SecIdentity.self)
    }

    /// Sertifikanın okunabilir adı (arayüzde göstermek için).
    public static func summary(of certificate: SecCertificate) -> String {
        (SecCertificateCopySubjectSummary(certificate) as String?) ?? L10n.t("cert.unnamed")
    }

    /// Sertifikanın künyesi: CN, sağlayıcı CN ve son geçerlilik tarihi.
    ///
    /// Alanlar tek tek opsiyonel: bazı sertifikalarda CN yok (yalnızca SAN),
    /// bazılarında sağlayıcı adı farklı alanlarda taşınıyor. Okunamayan alanı
    /// uydurmak yerine boş bırakıyoruz.
    public static func details(of certificate: SecCertificate) -> CertificateSummary {
        var commonName: CFString?
        SecCertificateCopyCommonName(certificate, &commonName)

        let values = SecCertificateCopyValues(certificate, nil, nil) as? [CFString: Any]
        return CertificateSummary(
            commonName: commonName as String?,
            issuerCommonName: issuerCommonName(from: values),
            validUntil: validUntil(from: values)
        )
    }

    /// Sertifikanın geçerli olduğu adlar (SAN girdileri).
    ///
    /// Neden gerekli: hostname uyuşmazlığında "adlar eşleşmiyor" demek
    /// yetmiyor; kullanıcının asıl sorusu "peki hangi adlar var". Sunucunun
    /// sunduğu sertifikanın adlarını göstermek, yanlış host mu yazıldığını
    /// yoksa sertifikanın mı eksik olduğunu tek bakışta ayırt ettiriyor.
    ///
    /// SAN yoksa CN'e düşülür — modern doğrulama CN'i yok sayar ama burada
    /// amaç doğrulamak değil, kullanıcıya ne olduğunu göstermek.
    public static func subjectNames(of certificate: SecCertificate) -> [String] {
        let values = SecCertificateCopyValues(
            certificate,
            [kSecOIDSubjectAltName] as CFArray,
            nil
        ) as? [String: Any]

        if let san = values?[kSecOIDSubjectAltName as String] as? [String: Any],
           let properties = san[kSecPropertyKeyValue as String] as? [[String: Any]] {
            // "Critical" bir ad değil, uzantının bayrağı; dışarıda bırakılır.
            let names = properties.compactMap { property -> String? in
                guard let label = property[kSecPropertyKeyLabel as String] as? String,
                      label != "Critical",
                      let value = property[kSecPropertyKeyValue as String] as? String
                else { return nil }
                return value
            }
            if !names.isEmpty { return names }
        }

        var commonName: CFString?
        SecCertificateCopyCommonName(certificate, &commonName)
        return (commonName as String?).map { [$0] } ?? []
    }

    /// sağlayıcı adı, X.509 issuer alanındaki CN girdisinden okunur.
    private static func issuerCommonName(from values: [CFString: Any]?) -> String? {
        guard let issuer = values?[kSecOIDX509V1IssuerName] as? [CFString: Any],
              let entries = issuer[kSecPropertyKeyValue] as? [[CFString: Any]] else { return nil }
        // Girdiler OID ile etiketli; CN'in OID'i 2.5.4.3.
        let commonNameOID = "2.5.4.3"
        for entry in entries {
            guard let label = entry[kSecPropertyKeyLabel] as? String, label == commonNameOID,
                  let value = entry[kSecPropertyKeyValue] as? String else { continue }
            return value
        }
        return nil
    }

    /// Son geçerlilik tarihi. Security framework bunu 2001 başlangıçlı
    /// (CFAbsoluteTime) saniye olarak veriyor.
    private static func validUntil(from values: [CFString: Any]?) -> Date? {
        guard let notAfter = values?[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let seconds = notAfter[kSecPropertyKeyValue] as? Double else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}
