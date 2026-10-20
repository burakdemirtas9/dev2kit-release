import SwiftUI
import Dev2KitCore

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
            Text(L10n.t("cookies.title"))
                .font(.title2).bold()
            Text(L10n.t("cookies.subtitle", appState.activeEnvironment?.name ?? L10n.t("environment.none")))
                .font(.secondaryText)
                .foregroundStyle(.secondary)

            if cookies.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text(L10n.t("cookies.empty.title"))
                    } icon: {
                        CookieIcon().frame(width: 44, height: 44)
                    }
                } description: {
                    Text(L10n.t("cookies.empty.message"))
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
                                    .font(.tinyText).foregroundStyle(Theme.up)
                            }
                            if cookie.isHTTPOnly {
                                Label("HttpOnly", systemImage: "eye.slash")
                                    .font(.tinyText).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 8) {
                            Text("\(cookie.domain)\(cookie.path)")
                                .font(.secondaryText)
                                .foregroundStyle(.secondary)
                            if let expires = cookie.expiresDate {
                                Text(L10n.date(expires))
                                    .font(.secondaryText)
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text(L10n.t("cookies.session"))
                                    .font(.secondaryText)
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
                    Label(L10n.t("cookies.deleteAll"), systemImage: "trash")
                }
                .disabled(cookies.isEmpty)
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L10n.t("common.refresh"))
                Spacer()
                Button(L10n.t("common.close")) { dismiss() }
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
