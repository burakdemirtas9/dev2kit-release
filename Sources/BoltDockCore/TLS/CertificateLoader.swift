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
            throw LoadError(message: "Sertifika dosyası bulunamadı: \(path)")
        }
        guard let data = FileManager.default.contents(atPath: expanded) else {
            throw LoadError(message: "Sertifika dosyası okunamadı: \(path)")
        }

        let blocks = pemBlocks(in: data)
        let sources = blocks.isEmpty ? [data] : blocks
        let certificates = sources.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }

        guard !certificates.isEmpty else {
            throw LoadError(message: "Dosya geçerli bir sertifika içermiyor (PEM veya DER bekleniyor).")
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
    /// Anahtar diske kopyalanmaz; yalnızca çağrı süresince bellekte kalır.
    public static func loadIdentity(atPath path: String, password: String) throws -> SecIdentity {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw LoadError(message: "İstemci sertifikası bulunamadı: \(path)")
        }
        guard let data = FileManager.default.contents(atPath: expanded) else {
            throw LoadError(message: "İstemci sertifikası okunamadı: \(path)")
        }

        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options, &items)

        switch status {
        case errSecSuccess:
            break
        case errSecAuthFailed:
            throw LoadError(message: "İstemci sertifikası parolası hatalı.")
        case errSecDecode:
            throw LoadError(message: "İstemci sertifikası çözümlenemedi (geçerli bir .p12 mi?).")
        default:
            throw LoadError(message: "İstemci sertifikası yüklenemedi (OSStatus \(status)).")
        }

        guard let entries = items as? [[String: Any]],
              let first = entries.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            throw LoadError(message: "Dosyada istemci kimliği bulunamadı.")
        }
        // SecIdentity CFTypeRef olarak gelir; tip güvenli dönüşüm.
        guard CFGetTypeID(identityRef as CFTypeRef) == SecIdentityGetTypeID() else {
            throw LoadError(message: "Dosyadaki öğe bir istemci kimliği değil.")
        }
        return unsafeBitCast(identityRef as CFTypeRef, to: SecIdentity.self)
    }

    /// Sertifikanın okunabilir adı (arayüzde göstermek için).
    public static func summary(of certificate: SecCertificate) -> String {
        (SecCertificateCopySubjectSummary(certificate) as String?) ?? "(isimsiz sertifika)"
    }
}
