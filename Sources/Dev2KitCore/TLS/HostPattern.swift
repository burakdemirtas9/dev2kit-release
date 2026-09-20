import Foundation

/// TLS profilinin hangi host'lara uygulanacağını belirleyen kalıp eşleştirme.
///
/// Neden gerekli: istemci sertifikası kimliği ifşa eden bir veridir. Her
/// host'a sunmak, bağlandığın her sunucuya kim olduğunu söylemek demektir.
/// Bu yüzden profiller yalnızca eşleşen host'lara uygulanır.
public enum HostPattern {
    /// Kalıp geçerli mi. Tek başına `*` reddedilir: profili tüm internete
    /// uygulamak istemci kimliğini her sunucuya sızdırır.
    public static func isValid(_ pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, trimmed != "*", trimmed != "*.", !trimmed.contains(" ") else {
            return false
        }
        if trimmed.hasPrefix("*.") {
            let rest = String(trimmed.dropFirst(2))
            // "*.com" gibi tek etiketli joker de çok geniş.
            return rest.contains(".") && !rest.contains("*")
        }
        return !trimmed.contains("*")
    }

    /// Host kalıba uyuyor mu.
    ///
    /// - Tam eşleşme: `api.firma.com`
    /// - Tek seviye joker: `*.firma.com` → `api.firma.com` eşleşir,
    ///   `a.b.firma.com` ve çıplak `firma.com` EŞLEŞMEZ (tarayıcı davranışı).
    public static func matches(_ pattern: String, host: String) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        let host = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard isValid(pattern), !host.isEmpty else { return false }

        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(1))  // ".firma.com"
            guard host.hasSuffix(suffix) else { return false }
            let label = String(host.dropLast(suffix.count))
            // Tek etiket olmalı: joker alt alan adlarını kapsamaz.
            return !label.isEmpty && !label.contains(".")
        }
        return pattern == host
    }

    /// Profil kalıplarından herhangi biri host'a uyuyor mu.
    public static func matchesAny(_ patterns: [String], host: String) -> Bool {
        patterns.contains { matches($0, host: host) }
    }
}
