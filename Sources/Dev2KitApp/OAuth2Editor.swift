import AppKit
import SwiftUI
import Dev2KitCore

/// OAuth2 yapılandırması ve yetkilendirme akışı (authorization code + PKCE).
/// Token vault'ta saklanır, workspace dosyasına asla yazılmaz.

/// OAuth2 yapılandırması ve yetkilendirme akışı.
struct OAuth2Editor: View {
    @Environment(AppState.self) private var appState
    @Binding var config: OAuth2Config

    private var token: OAuth2Token? { appState.storedToken(for: config) }
    private var isAuthorizing: Bool { appState.authorizingConfigID == config.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            tokenStatus

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                row("Authorization URL", "https://idp.example.com/authorize", $config.authorizationURL)
                row("Token URL", "https://idp.example.com/token", $config.tokenURL)
                row("Client ID", "istemci kimliği", $config.clientID)
                row("Client Secret", "boş bırak veya {{secret:isim}}", $config.clientSecret)
                row("Scopes", "openid profile email", $config.scopes)
            }

            HStack {
                Button {
                    appState.authorize(config)
                } label: {
                    if isAuthorizing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Tarayıcı bekleniyor…")
                        }
                    } else {
                        Label(token == nil ? "Yetkilendir" : "Yeniden Yetkilendir", systemImage: "person.badge.key")
                    }
                }
                .disabled(isAuthorizing || config.authorizationURL.isEmpty || config.clientID.isEmpty)

                if token != nil {
                    Button(role: .destructive) {
                        appState.clearToken(for: config)
                    } label: {
                        Label("Token'ı Sil", systemImage: "trash")
                    }
                    .disabled(isAuthorizing)
                }
            }

            if let message = appState.authMessage {
                Text(message)
                    .font(.secondaryText)
                    .foregroundStyle(message.contains("tamamlandı") ? Theme.up : Theme.down)
                    .lineLimit(3)
            }

            Label(
                "Sistem tarayıcısı kullanılır; uygulama parolanı hiç görmez. Token şifreli vault'ta saklanır, koleksiyon dosyasına yazılmaz. Yönlendirme yalnızca 127.0.0.1'e bağlanır.",
                systemImage: "lock.shield"
            )
            .font(.secondaryText)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var tokenStatus: some View {
        if let token {
            HStack(spacing: 6) {
                Image(systemName: token.isExpired() ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(token.isExpired() ? Theme.warning : Theme.up)
                if let expiry = token.expiresAt {
                    Text(token.isExpired()
                         ? "Token süresi doldu — gönderimde otomatik yenilenecek"
                         : "Token geçerli · \(expiry.formatted(date: .omitted, time: .shortened))'a kadar")
                } else {
                    Text("Token var (süre bilgisi yok)")
                }
                if token.refreshToken != nil {
                    Text("· yenilenebilir").foregroundStyle(.tertiary)
                }
            }
            .font(.secondaryText)
        } else {
            Label("Henüz token yok", systemImage: "circle.dashed")
                .font(.secondaryText)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        GridRow {
            Text(title)
                .font(.secondaryText)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            TemplateTextField(placeholder: placeholder, text: text, limit: .url)
        }
    }
}
