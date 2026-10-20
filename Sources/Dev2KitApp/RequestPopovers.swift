import AppKit
import SwiftUI
import Dev2KitCore

/// İstek çubuğundan açılan küçük panolar: cURL çıktısı, istek ayarları
/// (zaman aşımı, yönlendirme, çerez) ve "son gönderilenden farklı" rozeti.

/// İsteği cURL komutu olarak gösterip panoya kopyalatan popover.
/// Varsayılanda secret'lar {{secret:isim}} olarak bırakılır; kullanıcı
/// bilerek işaretlerse gerçek değerler çözülür.
struct CurlPopover: View {
    @Environment(AppState.self) private var appState
    let request: RequestModel
    @State private var includeSecrets = false
    @State private var copied = false

    private var curlText: String {
        appState.curlCommand(for: request, includeSecrets: includeSecrets)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("cURL Komutu")
                .font(.headline)

            ScrollView {
                Text(curlText)
                    .font(.secondaryMono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(width: 540, height: 180)
            .background(Theme.editorBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Toggle("Secret değerlerini çöz", isOn: $includeSecrets)
                .toggleStyle(.checkbox)
            if includeSecrets {
                Label("Dikkat: kopyalanan komut gerçek secret değerlerini içerecek.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.warning)
            }

            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(curlText, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Kopyalandı" : "Kopyala",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
        }
        .padding(14)
        .onChange(of: includeSecrets) {
            copied = false
        }
    }
}
/// İstek başına ağ ayarları: zaman aşımı, yönlendirme politikası, çerez.
struct RequestOptionsPopover: View {
    @Binding var options: RequestOptions

    var body: some View {
        Form {
            Section("Zaman Aşımı") {
                HStack {
                    TextField("", value: $options.timeout, format: .number)
                        .textFieldStyle(.input)
                        .frame(width: 60)
                    Stepper("saniye", value: $options.timeout, in: RequestOptions.timeoutRange, step: 5)
                }
            }

            Section("Yönlendirme") {
                Toggle("Yönlendirmeleri izle", isOn: $options.redirect.follow)
                if options.redirect.follow {
                    Stepper(
                        "En fazla \(options.redirect.maxRedirects) yönlendirme",
                        value: $options.redirect.maxRedirects,
                        in: 1...20
                    )
                    Toggle("https → http düşüşüne izin ver", isOn: $options.redirect.allowInsecureDowngrade)
                    if options.redirect.allowInsecureDowngrade {
                        Label(
                            "Trafik şifresiz hale gelebilir; yalnızca bilinçli test için aç.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.secondaryText)
                        .foregroundStyle(Theme.warning)
                    }
                    Label(
                        "Farklı bir host'a yönlendirmede Authorization ve Cookie başlıkları otomatik düşürülür.",
                        systemImage: "lock.shield"
                    )
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Çerezler") {
                Toggle("Oturum çerezlerini kullan", isOn: $options.sendCookies)
                Label(
                    "Çerezler yalnızca bellekte ve environment başına ayrı tutulur; diske yazılmaz.",
                    systemImage: "info.circle"
                )
                .font(.secondaryText)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .frame(maxHeight: 480)
    }
}
/// Nokta + metin: "değişti" işaretini sade tutar.
struct DirtyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(.system(size: 7))
                .foregroundStyle(Theme.warning)
            configuration.title
                .foregroundStyle(.secondary)
        }
    }
}
