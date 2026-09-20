import Foundation

/// Yöneticinin belirlediği izinli host listesi.
///
/// Dosya: `/Library/Application Support/dev2kit/policy.json`
/// ```json
/// { "allowedHosts": ["*.firma.local", "api.partner.com", "localhost", "127.0.0.1"] }
/// ```
/// - `*.firma.local` tüm alt alan adlarını kapsar, `firma.local`'ın kendisini
///   kapsamaz; ikisi de isteniyorsa ikisi de yazılır.
/// - Port ve şema dikkate alınmaz; kısıt host düzeyindedir.
/// - Boş liste geçerlidir ve hiçbir host'a izin vermez.
public struct HostPolicy: Equatable, Sendable {
    public let allowedHosts: [String]

    public func allows(host rawHost: String) -> Bool {
        let host = Self.normalize(rawHost)
        guard !host.isEmpty else { return false }
        return allowedHosts.contains { pattern in
            if pattern.hasPrefix("*.") {
                return host.hasSuffix(String(pattern.dropFirst()))
            }
            return host == pattern
        }
    }

    /// Küçük harf, sondaki nokta ve IPv6 köşeli parantezleri atılır.
    static func normalize(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }
}

/// Politikanın o anki durumu.
public enum HostPolicyState: Equatable, Sendable {
    /// Dosya yok: host kısıtı uygulanmaz.
    case notConfigured
    case active(HostPolicy)
    /// Dosya var ama kullanılamıyor. Yönetici bir kısıt koymak istemiş;
    /// dosya bozuk diye kısıtın sessizce kalkması açık olurdu, bu yüzden
    /// bu durumda TÜM gönderimler engellenir (fail closed).
    case invalid(reason: String)

    /// URL politikaya aykırıysa kullanıcıya gösterilecek sebep, değilse nil.
    public func violation(for url: URL?) -> String? {
        switch self {
        case .notConfigured:
            return nil
        case .invalid(let reason):
            return "Yönetici politika dosyası okunamadı, tüm gönderimler durduruldu: \(reason)"
        case .active(let policy):
            let host = url?.host ?? ""
            guard policy.allows(host: host) else {
                return "\"\(host.isEmpty ? "(host yok)" : host)\" yöneticinin izin verdiği host'lar arasında değil."
            }
            return nil
        }
    }
}

public enum HostPolicyLoader {
    public static let defaultURL = URL(fileURLWithPath: "/Library/Application Support/dev2kit/policy.json")

    /// - Parameter requireRootOwnership: Dosya ve bulunduğu dizin root'a ait
    ///   olmalı. Yoksa kullanıcı (ya da onun adına çalışan herhangi bir süreç)
    ///   dosyayı değiştirip kısıtı kaldırabilirdi. Yalnızca testlerde kapatılır.
    public static func load(
        from url: URL = defaultURL,
        requireRootOwnership: Bool = true,
        fileManager: FileManager = .default
    ) -> HostPolicyState {
        guard fileManager.fileExists(atPath: url.path) else { return .notConfigured }
        if let problem = permissionProblem(at: url, requireRootOwnership: requireRootOwnership, fileManager: fileManager) {
            return .invalid(reason: problem)
        }
        guard let data = try? Data(contentsOf: url) else {
            return .invalid(reason: "dosya okunamadı (\(url.path))")
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> HostPolicyState {
        struct File: Decodable { let allowedHosts: [String] }
        // Anahtar adındaki bir yazım hatası da (allowedHost) hata sayılır:
        // kısıt kazara devre dışı kalmasın.
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            return .invalid(reason: "geçerli bir JSON değil ya da \"allowedHosts\" listesi yok")
        }
        var patterns: [String] = []
        for raw in file.allowedHosts {
            let pattern = HostPolicy.normalize(raw)
            guard isValidPattern(pattern) else {
                return .invalid(reason: "geçersiz host kalıbı: \"\(raw)\"")
            }
            patterns.append(pattern)
        }
        return .active(HostPolicy(allowedHosts: patterns))
    }

    /// Yalnızca host ya da `*.alan.adi`. Şema, yol, port, kullanıcı bilgisi
    /// ve tek başına `*` kabul edilmez: yöneticinin niyeti belirsiz kalmasın.
    static func isValidPattern(_ pattern: String) -> Bool {
        let body = pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : pattern
        guard !body.isEmpty, !body.hasPrefix("."), !body.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.:")
        return body.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func permissionProblem(
        at url: URL,
        requireRootOwnership: Bool,
        fileManager: FileManager
    ) -> String? {
        for path in [url.path, url.deletingLastPathComponent().path] {
            guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
                return "izinleri okunamadı (\(path))"
            }
            if requireRootOwnership, (attributes[.ownerAccountID] as? Int) != 0 {
                return "\(path) root'a ait olmalı"
            }
            let permissions = attributes[.posixPermissions] as? Int ?? 0
            if permissions & 0o022 != 0 {
                return "\(path) grup ya da diğer kullanıcılar tarafından yazılabilir olmamalı"
            }
        }
        return nil
    }
}
