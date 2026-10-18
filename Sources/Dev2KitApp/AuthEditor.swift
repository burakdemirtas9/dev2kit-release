import AppKit
import SwiftUI
import Dev2KitCore

/// Kimlik doğrulama düzenleyicisi. Gerçek sırlar buraya düz yazılmamalı;
/// `{{secret:isim}}` referansı vault'tan çözülür.

struct AuthEditor: View {
    @Binding var auth: AuthConfig

    /// Görünen ad; tür ve "boş hali" kuralı Core'da (`AuthKind`).
    private static func label(_ kind: AuthKind) -> String {
        switch kind {
        case .none: return "Yok"
        case .basic: return "Basic"
        case .bearer: return "Bearer"
        case .apiKey: return "API Key"
        case .oauth2: return "OAuth2"
        }
    }

    private var kind: Binding<AuthKind> {
        Binding(get: { auth.kind }, set: { auth = .empty($0) })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Sol sütun: auth türü dropdown'ı (Postman yerleşimi)
            VStack(alignment: .leading, spacing: 6) {
                Text("Auth Türü")
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                Picker("", selection: kind) {
                    ForEach(AuthKind.allCases) { Text(Self.label($0)).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 140, alignment: .leading)
            }
            .padding(12)

            Divider()

            // Sağ sütun: seçilen türün alanları
            VStack(alignment: .leading, spacing: 10) {
                switch auth {
                case .none:
                    Text("Bu istek kimlik doğrulama kullanmıyor.")
                        .foregroundStyle(.secondary)
                case .basic(let username, let password):
                    authField("Kullanıcı Adı", placeholder: "kullanıcı adı", text: Binding(
                        get: { username },
                        set: { auth = .basic(username: $0, password: password) }
                    ))
                    authField("Şifre", placeholder: "{{secret:isim}}", text: Binding(
                        get: { password },
                        set: { auth = .basic(username: username, password: $0) }
                    ))
                case .bearer(let token):
                    authField("Token", placeholder: "{{secret:isim}}", text: Binding(
                        get: { token },
                        set: { auth = .bearer(token: $0) }
                    ))
                case .apiKey(let key, let value, let location):
                    authField("Key", placeholder: "X-Api-Key", text: Binding(
                        get: { key },
                        set: { auth = .apiKey(key: $0, value: value, location: location) }
                    ))
                    authField("Değer", placeholder: "{{secret:isim}}", text: Binding(
                        get: { value },
                        set: { auth = .apiKey(key: key, value: $0, location: location) }
                    ))
                    HStack {
                        fieldLabel("Konum")
                        Picker("", selection: Binding(
                            get: { location },
                            set: { auth = .apiKey(key: key, value: value, location: $0) }
                        )) {
                            Text("Header").tag(AuthConfig.APIKeyLocation.header)
                            Text("Query Param").tag(AuthConfig.APIKeyLocation.queryParam)
                        }
                        .labelsHidden()
                        .frame(width: 160, alignment: .leading)
                    }
                case .oauth2(let oauthConfig):
                    OAuth2Editor(config: Binding(
                        get: { oauthConfig },
                        set: { auth = .oauth2($0) }
                    ))
                }

                if kind.wrappedValue != .none, kind.wrappedValue != .oauth2 {
                    Label(
                        "Düz metin secret yazma: değeri Secrets'a ekleyip {{secret:isim}} olarak referans ver — {{ yazınca öneriler açılır.",
                        systemImage: "lock.shield"
                    )
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .frame(width: 110, alignment: .trailing)
            .foregroundStyle(.secondary)
    }

    private func authField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(alignment: .top) {
            fieldLabel(title)
                .padding(.top, 3)
            TemplateTextField(placeholder: placeholder, text: text)
        }
    }
}
