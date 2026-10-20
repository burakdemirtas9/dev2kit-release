import SwiftUI
import Dev2KitCore

/// TLS güven hatasından sonra çıkan "bu host'u şu profile ekleyeyim mi" teklifi.
///
/// Kalıpları otomatik genişletmiyoruz — host kalıbı yalnızca hangi CA'nın
/// geçerli olduğunu değil, istemci sertifikasının KİME sunulacağını da
/// belirliyor ve `.local` gibi adlar yerel ağda sahipsiz. Karar kullanıcının;
/// kabul edilirse profile yazılıyor, yani denetlenebilir kalıyor.
struct TLSSuggestionBanner: View {
    @Environment(AppState.self) private var appState
    let match: TLSPatternSuggestion.Match
    @State private var showingConfirm = false

    var body: some View {
        // Öneri bilgi türünde (eskiden sarı zemin uyarı gibi okunuyordu);
        // içindeki riskler ayrı uyarı satırları. Mor birincil eylem öneriyi taşır.
        MessageBanner(
            kind: .info,
            title: "Bu host'u “\(match.profileName)” profiline ekle?",
            message: "\(match.hostToAdd) için profil yok; “\(match.profileName)” \(match.matchedPattern) kalıbını içeriyor. İstek kendiliğinden yeniden gönderilmez.",
            lines: warnings.map { MessageLine(.warning, $0) }
        ) {
            Button(match.carriesClientCertificate ? "Ekle…" : "Profile Ekle") {
                // Kimlik taşıyan profilde tek tık yok: kullanıcı neyi
                // onayladığını yazılı görsün.
                if match.carriesClientCertificate {
                    showingConfirm = true
                } else {
                    appState.acceptTLSSuggestion()
                }
            }
            .buttonStyle(PrimaryActionButtonStyle())
            // Bilinçli olarak `.defaultAction` DEĞİL: kutu kullanıcı yazarken
            // beliriyor ve ⏎ güvenlikle ilgili bir değişikliği tek tuşa
            // indirirdi. (Sandbox denemesinde tam olarak bu oldu: sıradan
            // bir ⏎ host'u profile ekledi.)
            Button("Profili Aç") {
                appState.showTLSSettings(profileID: match.profileID)
            }
            Button("Vazgeç") {
                appState.declineTLSSuggestion()
            }
            .buttonStyle(.borderless)
        }
        .confirmationDialog(
            "\(match.hostToAdd) “\(match.profileName)” profiline eklensin mi?",
            isPresented: $showingConfirm,
            titleVisibility: .visible
        ) {
            // Yıkıcı değil: ekleme geri alınabilir. Risk mesajda yazılı.
            Button("Profile Ekle") { appState.acceptTLSSuggestion() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    /// Kullanıcının bilmesi gereken riskler. Sıra önemli: kimlik ifşası
    /// adın sahipsizliğinden daha ağır.
    private var warnings: [String] {
        var result: [String] = []
        if match.carriesClientCertificate {
            result.append("Bu profil bir istemci sertifikası taşıyor: kimliğin bu ada da sunulacak.")
        }
        if match.isNonPublicSuffix {
            result.append("Bu ad kayıtlı değil; aynı yerel ağdaki herhangi bir cihaz onu üstlenebilir.")
        }
        return result
    }

    private var confirmationMessage: String {
        var lines = [
            "Kalıcı olarak eklenir; istediğin zaman TLS > Host Profilleri'nden çıkarabilirsin.",
        ]
        lines.append(contentsOf: warnings)
        lines.append("İstek kendiliğinden yeniden gönderilmez.")
        return lines.joined(separator: "\n\n")
    }
}
