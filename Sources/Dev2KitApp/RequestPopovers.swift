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
            Text(L10n.t("curl.title"))
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

            Toggle(L10n.t("curl.resolveSecrets"), isOn: $includeSecrets)
                .toggleStyle(.checkbox)
            if includeSecrets {
                Label(L10n.t("curl.resolveSecrets.warning"),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.warning)
            }

            HStack {
                Spacer()
                Button {
                    if includeSecrets {
                        // Çözülmüş secret'lar: yalnızca bu Mac, pano geçmişine girmez.
                        SensitivePasteboard.copy(curlText)
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(curlText, forType: .string)
                    }
                    copied = true
                } label: {
                    Label(copied ? L10n.t("common.copied") : L10n.t("common.copy"),
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
            Section(L10n.t("options.timeout")) {
                HStack {
                    TextField("", value: $options.timeout, format: .number)
                        .textFieldStyle(.input)
                        .frame(width: 60)
                    Stepper(L10n.t("options.seconds"), value: $options.timeout, in: RequestOptions.timeoutRange, step: 5)
                }
            }

            Section(L10n.t("options.redirects")) {
                Toggle(L10n.t("options.followRedirects"), isOn: $options.redirect.follow)
                if options.redirect.follow {
                    Stepper(
                        L10n.plural("options.maxRedirects", count: options.redirect.maxRedirects),
                        value: $options.redirect.maxRedirects,
                        in: 1...20
                    )
                    Toggle(L10n.t("options.allowDowngrade"), isOn: $options.redirect.allowInsecureDowngrade)
                    if options.redirect.allowInsecureDowngrade {
                        Label(
                            L10n.t("options.allowDowngrade.warning"),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.secondaryText)
                        .foregroundStyle(Theme.warning)
                    }
                    Label(
                        L10n.t("options.crossHostNote"),
                        systemImage: "lock.shield"
                    )
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                }
            }

            Section(L10n.t("options.cookies")) {
                Toggle(L10n.t("options.useCookies"), isOn: $options.sendCookies)
                Label(
                    L10n.t("options.cookiesNote"),
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
