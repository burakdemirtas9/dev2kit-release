import AppKit
import Foundation
import SwiftUI
import Dev2KitCore

/// TLS tarafı: kurum güven deposu (cacerts), host bazlı TLS profilleri ve
/// oturum çerezleri. Üçü de istek motorunun güvenlik yapılandırmasını besler.

extension AppState {
    func reloadTrustStore() {
        let result = TrustStore.load()
        trustStore = result
        engine.trustStoreCertificates = result.certificates
    }

    func installCertificate(from url: URL) -> String {
        do {
            let destination = try TrustStore.install(from: url)
            reloadTrustStore()
            return "\(destination.lastPathComponent) güven deposuna eklendi."
        } catch {
            return "Eklenemedi: \(error.localizedDescription)"
        }
    }

    func removeCertificate(path: String) -> String {
        do {
            try TrustStore.remove(path: path)
            reloadTrustStore()
            return "Sertifika kaldırıldı."
        } catch {
            return error.localizedDescription
        }
    }

    func addTLSProfile() -> UUID {
        let profile = TLSProfile()
        workspace.tlsProfiles.append(profile)
        syncTLSProfiles()
        persist()
        return profile.id
    }

    func deleteTLSProfile(_ id: UUID) {
        workspace.tlsProfiles.removeAll { $0.id == id }
        syncTLSProfiles()
        persist()
    }

    func tlsProfileBinding(_ id: UUID) -> Binding<TLSProfile>? {
        guard workspace.tlsProfiles.contains(where: { $0.id == id }) else { return nil }
        let fallback = workspace.tlsProfiles.first { $0.id == id }!
        return Binding(
            get: { self.workspace.tlsProfiles.first { $0.id == id } ?? fallback },
            set: { newValue in
                guard let index = self.workspace.tlsProfiles.firstIndex(id: id) else { return }
                self.workspace.tlsProfiles[index] = newValue
                self.syncTLSProfiles()
                self.persistSoon()
            }
        )
    }

    // MARK: - Profil önerisi

    /// Öneriyi doğuran hata kodları. Sunucu sertifikası doğrulanamadı ya da
    /// sunucu istemci sertifikası istedi — ikisi de "bu host'un profili
    /// eksik olabilir" demek.
    ///
    /// Ölçüldü: kendinden imzalı sertifika sunan yerel bir sunucuya istek
    /// `-1202` (`serverCertificateUntrusted`) veriyor, `.cancelled` değil —
    /// yani iptal dalına düşüp sessizce yutulmuyor.
    static let tlsTrustFailureCodes: Set<URLError.Code> = [
        .serverCertificateUntrusted,
        .serverCertificateHasBadDate,
        .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid,
        .secureConnectionFailed,
        .clientCertificateRequired,
        .clientCertificateRejected,
    ]

    /// TLS hatası veren istek için profil önerisi arar.
    ///
    /// Host, hatanın `failingURL`'inden alınır: istek URL'i `{{degisken}}`
    /// içerebilir, çözülmüş hali yalnızca motorun elinde.
    func offerTLSSuggestion(for error: Error) {
        guard let host = Self.tlsFailureHost(in: error)?.lowercased(),
              !declinedTLSSuggestionHosts.contains(host),
              let match = TLSPatternSuggestion.suggestion(for: host, in: workspace.tlsProfiles)
        else { return }
        tlsSuggestion = match
    }

    /// Hata TLS güven sorunuysa ilgili host. Değilse `nil`.
    ///
    /// İki kaynak var: sistem doğrulamasının verdiği `URLError` ve bizim
    /// doğrulayıcımızın reddi (`tlsRejected`). İkincisi olmasa profili olan
    /// host'larda öneri hiç çıkmazdı — oysa asıl ihtiyaç orada.
    static func tlsFailureHost(in error: Error) -> String? {
        if case RequestEngineError.tlsRejected(let host, _) = error {
            return host
        }
        guard let urlError = error as? URLError,
              tlsTrustFailureCodes.contains(urlError.code)
        else { return nil }
        return urlError.failingURL?.host
    }

    /// Kabul: TAM host profile yazılır ve kalıcı olur — Host Profilleri
    /// ekranında görünür, oradan silinebilir. Gizli durum bırakmıyoruz.
    /// İstek bilerek YENİDEN GÖNDERİLMEZ; kullanıcı ne olduğunu görsün.
    func acceptTLSSuggestion() {
        defer { tlsSuggestion = nil }
        guard let match = tlsSuggestion,
              let index = workspace.tlsProfiles.firstIndex(id: match.profileID),
              !workspace.tlsProfiles[index].hostPatterns.contains(match.hostToAdd)
        else { return }
        workspace.tlsProfiles[index].hostPatterns.append(match.hostToAdd)
        syncTLSProfiles()
        persist()
    }

    func declineTLSSuggestion() {
        if let host = tlsSuggestion?.hostToAdd {
            declinedTLSSuggestionHosts.insert(host)
        }
        tlsSuggestion = nil
    }

    /// Motor kendi kopyasını tutar; profil değişince güncellenmeli.
    private func syncTLSProfiles() {
        engine.tlsProfiles = workspace.tlsProfiles
    }

    /// Aktif environment'ın çerez kavanozu (yalnızca bellekte tutulur).
    func activeCookies() -> [HTTPCookie] {
        engine.cookies(in: cookieScope)
    }

    func clearActiveCookies() {
        engine.clearCookies(in: cookieScope)
    }
}
