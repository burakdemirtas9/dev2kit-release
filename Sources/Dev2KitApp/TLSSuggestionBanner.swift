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
            title: L10n.t("tlsSuggestion.title", match.profileName),
            message: L10n.t("tlsSuggestion.message", match.hostToAdd, match.profileName, match.matchedPattern),
            lines: warnings.map { MessageLine(.warning, $0) }
        ) {
            Button(match.carriesClientCertificate ? L10n.t("tlsSuggestion.addEllipsis") : L10n.t("tlsSuggestion.add")) {
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
            Button(L10n.t("tlsSuggestion.open")) {
                appState.showTLSSettings(profileID: match.profileID)
            }
            Button(L10n.t("common.cancel")) {
                appState.declineTLSSuggestion()
            }
            .buttonStyle(.borderless)
        }
        .confirmationDialog(
            L10n.t("tlsSuggestion.confirm.title", match.hostToAdd, match.profileName),
            isPresented: $showingConfirm,
            titleVisibility: .visible
        ) {
            // Yıkıcı değil: ekleme geri alınabilir. Risk mesajda yazılı.
            Button(L10n.t("tlsSuggestion.add")) { appState.acceptTLSSuggestion() }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    /// Kullanıcının bilmesi gereken riskler. Sıra önemli: kimlik ifşası
    /// adın sahipsizliğinden daha ağır.
    private var warnings: [String] {
        var result: [String] = []
        if match.carriesClientCertificate {
            result.append(L10n.t("tlsSuggestion.warning.identity"))
        }
        if match.isNonPublicSuffix {
            result.append(L10n.t("tlsSuggestion.warning.local"))
        }
        return result
    }

    private var confirmationMessage: String {
        var lines = [
            L10n.t("tlsSuggestion.confirm.message"),
        ]
        lines.append(contentsOf: warnings)
        lines.append(L10n.t("tlsSuggestion.noResend"))
        return lines.joined(separator: "\n\n")
    }
}
