import SwiftUI
import BoltDockCore

/// Aktif environment'ın çerez kavanozunu gösterir ve temizlemeye izin verir.
///
/// Çerezler oturum kimlik bilgisidir: burada DEĞERLERİ gösterilmez, yalnızca
/// hangi alan adına hangi ad altında çerez tutulduğu ve güvenlik bayrakları
/// listelenir. Kavanoz bellekte durur, diske hiç yazılmaz.
struct CookiesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var cookies: [HTTPCookie] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Çerezler")
                .font(.title2).bold()
            Text("Aktif environment: \(appState.activeEnvironment?.name ?? "Environment Yok"). Çerezler environment başına ayrı tutulur ve yalnızca bellekte durur — uygulama kapanınca silinir, diske yazılmaz.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if cookies.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("Çerez yok")
                    } icon: {
                        CookieIcon().frame(width: 44, height: 44)
                    }
                } description: {
                    Text("Sunucular Set-Cookie döndükçe burada görünür.")
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                List(cookies, id: \.self) { cookie in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(cookie.name)
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.semibold)
                            Text("••••••••").foregroundStyle(.tertiary)
                            Spacer()
                            if cookie.isSecure {
                                Label("Secure", systemImage: "lock.fill")
                                    .font(.caption2).foregroundStyle(Theme.up)
                            }
                            if cookie.isHTTPOnly {
                                Label("HttpOnly", systemImage: "eye.slash")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 8) {
                            Text("\(cookie.domain)\(cookie.path)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let expires = cookie.expiresDate {
                                Text(expires.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("oturum")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
                .frame(minHeight: 200)
            }

            HStack {
                Button(role: .destructive) {
                    appState.clearActiveCookies()
                    reload()
                } label: {
                    Label("Tümünü Sil (oturumu kapat)", systemImage: "trash")
                }
                .disabled(cookies.isEmpty)
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Yenile")
                Spacer()
                Button("Kapat") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
        .onAppear(perform: reload)
    }

    private func reload() {
        cookies = appState.activeCookies()
            .sorted { ($0.domain, $0.name) < ($1.domain, $1.name) }
    }
}
