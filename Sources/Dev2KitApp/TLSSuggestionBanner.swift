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
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("\(match.hostToAdd) için TLS profili yok.")
                    .fontWeight(.medium)
            } icon: {
                Image(systemName: "lock.trianglebadge.exclamationmark")
            }

            Text("“\(match.profileName)” profili \(match.matchedPattern) kalıbını içeriyor. Bu host'u da o profile eklemek ister misin?")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Profili Aç") {
                    appState.showTLSSettings()
                }
                Spacer()
                Button("Vazgeç") {
                    appState.declineTLSSuggestion()
                }
                Button(match.carriesClientCertificate ? "Ekle…" : "Profile Ekle") {
                    // Kimlik taşıyan profilde tek tık yok: kullanıcı neyi
                    // onayladığını yazılı görsün.
                    if match.carriesClientCertificate {
                        showingConfirm = true
                    } else {
                        appState.acceptTLSSuggestion()
                    }
                }
                // Bilinçli olarak `.defaultAction` DEĞİL: kutu kullanıcı yazarken
                // beliriyor ve ⏎ güvenlikle ilgili bir değişikliği tek tuşa
                // indirirdi. (Sandbox denemesinde tam olarak bu oldu: sıradan
                // bir ⏎ host'u profile ekledi.)
            }
        }
        .font(.callout)
        .padding(12)
        .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .confirmationDialog(
            "\(match.hostToAdd) eklensin mi?",
            isPresented: $showingConfirm,
            titleVisibility: .visible
        ) {
            Button("Ekle", role: .destructive) { appState.acceptTLSSuggestion() }
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
            "“\(match.profileName)” profiline eklenecek ve kalıcı olacak; Host Profilleri ekranından geri alabilirsin.",
        ]
        lines.append(contentsOf: warnings)
        lines.append("İstek kendiliğinden yeniden gönderilmez.")
        return lines.joined(separator: "\n\n")
    }
}
