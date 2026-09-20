import Foundation
import Security

/// Kurum CA'larının toplu olarak konulduğu güven deposu.
///
/// Java'daki `$JAVA_HOME/lib/security/cacerts` mantığı: güvenlik ekibi
/// sertifikaları bir yere bırakır, uygulama hepsini otomatik yükler.
/// Fark: keystore formatı yerine düz bir dizin kullanılır — `.pem`/`.crt`/
/// `.der` dosyaları kopyalanır, `keytool` gibi bir araca gerek kalmaz.
///
/// İki arama yolu vardır:
/// - **Makine geneli** `/Library/Application Support/dev2kit/cacerts`
///   Yazmak için yönetici hakkı gerekir; MDM ile dağıtıma uygundur ve
///   makinedeki tüm kullanıcılar için geçerlidir.
/// - **Kullanıcı** `~/Library/Application Support/dev2kit/cacerts`
///   Kullanıcının kendi ekledikleri.
///
/// Ek olarak `DEV2KIT_CA_PATH` ortam değişkeni (`:` ile ayrılmış dizinler)
/// okunur; Java'nın `-Djavax.net.ssl.trustStore` karşılığı.
///
/// GÜVENLİK NOTU: Buraya dosya bırakmak güven genişletmektir. Bu yüzden
/// yüklenen her sertifika arayüzde listelenir — sessiz güven genişlemesi
/// olmaz, kullanıcı neye güvendiğini görebilir.
public enum TrustStore {
    public static let directoryName = "cacerts"
    public static let environmentVariable = "DEV2KIT_CA_PATH"
    private static let extensions: Set<String> = ["pem", "crt", "cer", "der", "cert"]

    /// Yüklenmiş tek bir sertifika.
    public struct Entry: Identifiable, @unchecked Sendable {
        public let id: String
        public let path: String
        public let fileName: String
        public let source: Source
        public let subject: String
        /// Sertifika bir CA mı. Belirlenemezse `nil`.
        public let isCertificateAuthority: Bool?
        public let expiresAt: Date?
        public let certificate: SecCertificate

        init(
            id: String, path: String, fileName: String, source: Source,
            subject: String, isCertificateAuthority: Bool?, expiresAt: Date?,
            certificate: SecCertificate
        ) {
            self.id = id
            self.path = path
            self.fileName = fileName
            self.source = source
            self.subject = subject
            self.isCertificateAuthority = isCertificateAuthority
            self.expiresAt = expiresAt
            self.certificate = certificate
        }

        public var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt < Date()
        }
    }

    public enum Source: String, Sendable {
        case machine = "Makine geneli"
        case user = "Kullanıcı"
        case environment = "DEV2KIT_CA_PATH"
    }

    public struct LoadResult: Sendable {
        public let entries: [Entry]
        /// Okunamayan dosyalar — sessizce yutulmaz, kullanıcıya bildirilir.
        public let problems: [String]

        public init(entries: [Entry] = [], problems: [String] = []) {
            self.entries = entries
            self.problems = problems
        }

        public var certificates: [SecCertificate] { entries.map(\.certificate) }
    }

    // MARK: - Dizinler

    public static var machineDirectory: URL {
        URL(fileURLWithPath: "/Library/Application Support/dev2kit/\(directoryName)")
    }

    public static var userDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent(directoryName)
    }

    public static func environmentDirectories() -> [URL] {
        guard let raw = ProcessInfo.processInfo.environment[environmentVariable] else { return [] }
        return raw.split(separator: ":")
            .map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.path.isEmpty }
    }

    /// Kullanıcının sertifika bırakabileceği dizini oluşturur ve döner.
    @discardableResult
    public static func prepareUserDirectory() throws -> URL {
        let directory = userDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Yükleme

    public static func load() -> LoadResult {
        var entries: [Entry] = []
        var problems: [String] = []
        var seenPaths = Set<String>()

        let sources: [(URL, Source)] =
            [(machineDirectory, .machine), (userDirectory, .user)]
            + environmentDirectories().map { ($0, .environment) }

        for (directory, source) in sources {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }

            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard extensions.contains(file.pathExtension.lowercased()) else { continue }
                guard seenPaths.insert(file.path).inserted else { continue }
                do {
                    let certificates = try CertificateLoader.loadCertificates(atPath: file.path)
                    for (index, certificate) in certificates.enumerated() {
                        entries.append(
                            Entry(
                                id: "\(file.path)#\(index)",
                                path: file.path,
                                fileName: file.lastPathComponent,
                                source: source,
                                subject: CertificateLoader.summary(of: certificate),
                                isCertificateAuthority: isCA(certificate),
                                expiresAt: expiry(of: certificate),
                                certificate: certificate
                            )
                        )
                    }
                } catch {
                    problems.append("\(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return LoadResult(entries: entries, problems: problems)
    }

    // MARK: - Yönetim

    /// Seçilen sertifikayı kullanıcı güven deposuna kopyalar.
    /// Aynı adda dosya varsa üzerine yazmaz, sonuna sayı ekler.
    @discardableResult
    public static func install(from source: URL) throws -> URL {
        // Kopyalamadan önce geçerli bir sertifika mı doğrula: bozuk dosyayı
        // depoya koyup her açılışta hata üretmek anlamsız.
        _ = try CertificateLoader.loadCertificates(atPath: source.path)

        let directory = try prepareUserDirectory()
        let fileManager = FileManager.default
        var destination = directory.appendingPathComponent(source.lastPathComponent)
        var counter = 2
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.isEmpty ? "pem" : source.pathExtension
        while fileManager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    public static func remove(path: String) throws {
        // Yalnızca kullanıcı dizinindekiler silinebilir; makine geneli
        // sertifikalar yönetici/MDM sorumluluğundadır.
        guard path.hasPrefix(userDirectory.path) else {
            throw CertificateLoader.LoadError(
                message: "Bu sertifika makine geneli dizinde; kaldırmak için yönetici hakkı gerekir."
            )
        }
        try FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Sertifika bilgisi

    /// Basic Constraints uzantısından CA olup olmadığını çıkarır.
    /// Belirlenemezse `nil` döner — yanlış bilgi vermektense bilinmez demek yeğdir.
    static func isCA(_ certificate: SecCertificate) -> Bool? {
        guard let values = SecCertificateCopyValues(
            certificate,
            [kSecOIDBasicConstraints] as CFArray,
            nil
        ) as? [String: Any],
            let constraints = values[kSecOIDBasicConstraints as String] as? [String: Any],
            let properties = constraints[kSecPropertyKeyValue as String] as? [[String: Any]]
        else { return nil }

        for property in properties {
            guard let label = property[kSecPropertyKeyLabel as String] as? String,
                  let value = property[kSecPropertyKeyValue as String] as? String else { continue }
            if label.localizedCaseInsensitiveContains("Certificate Authority")
                || label.localizedCaseInsensitiveContains("Sertifika Yetkilisi") {
                return value.localizedCaseInsensitiveContains("yes")
                    || value.localizedCaseInsensitiveContains("evet")
                    || value == "1"
            }
        }
        return nil
    }

    static func expiry(of certificate: SecCertificate) -> Date? {
        guard let values = SecCertificateCopyValues(
            certificate,
            [kSecOIDX509V1ValidityNotAfter] as CFArray,
            nil
        ) as? [String: Any],
            let validity = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
            let interval = validity[kSecPropertyKeyValue as String] as? Double
        else { return nil }
        // Security framework bu değeri 2001 referans tarihine göre verir.
        return Date(timeIntervalSinceReferenceDate: interval)
    }
}
