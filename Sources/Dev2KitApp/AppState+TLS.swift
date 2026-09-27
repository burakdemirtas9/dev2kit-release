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
                guard let index = self.workspace.tlsProfiles.firstIndex(where: { $0.id == id }) else { return }
                self.workspace.tlsProfiles[index] = newValue
                self.syncTLSProfiles()
                self.persistSoon()
            }
        )
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
