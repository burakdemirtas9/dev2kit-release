import SwiftUI
import Dev2KitCore

/// Environment oluşturma/düzenleme ekranı: solda environment listesi,
/// sağda seçilenin adı ve değişkenleri.
struct EnvironmentsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?

    var body: some View {
        @Bindable var state = appState
        VStack(alignment: .leading, spacing: 12) {
            Text("Environment'lar")
                .font(.title2).bold()

            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selectedID) {
                        ForEach(appState.workspace.environments) { environment in
                            HStack {
                                Text(environment.name).lineLimit(1)
                                Spacer()
                                if environment.id == appState.workspace.activeEnvironmentID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.up)
                                        .help("Aktif environment")
                                }
                            }
                            .tag(environment.id)
                        }
                    }
                    HStack {
                        Button {
                            selectedID = appState.addEnvironment()
                        } label: {
                            Image(systemName: "plus")
                        }
                        Button {
                            if let selectedID {
                                appState.deleteEnvironment(selectedID)
                                self.selectedID = appState.workspace.environments.first?.id
                            }
                        } label: {
                            Image(systemName: "minus")
                        }
                        .disabled(selectedID == nil)
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(6)
                }
                .frame(width: 200)

                Divider()

                if let selectedID, let binding = appState.environmentBinding(selectedID) {
                    EnvironmentDetail(environment: binding, isActive: appState.workspace.activeEnvironmentID == selectedID) {
                        state.workspace.activeEnvironmentID = selectedID
                        appState.persist()
                    }
                } else {
                    ContentUnavailableView(
                        "Environment seç",
                        systemImage: "globe",
                        description: Text("Soldan seç veya + ile yeni oluştur.")
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(minHeight: 320)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

            HStack {
                Spacer()
                Button("Kapat") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 620)
        .onAppear {
            selectedID = appState.workspace.activeEnvironmentID ?? appState.workspace.environments.first?.id
        }
    }
}

private struct EnvironmentDetail: View {
    @Binding var environment: EnvironmentModel
    let isActive: Bool
    let makeActive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Environment adı", text: $environment.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                if isActive {
                    Label("Aktif", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.up)
                        .font(.caption)
                } else {
                    Button("Aktif Yap", action: makeActive)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            Text("Değişkenler — isteklerde {{isim}} olarak kullanılır. Secret değerleri buraya değil Secrets'a yaz.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)

            KeyValueEditor(
                entries: $environment.variables,
                keyPlaceholder: "isim (ör: baseUrl)",
                valuePlaceholder: "değer (ör: https://api.example.com)"
            )

            Divider()
            TokenVariablesEditor(environment: $environment)
        }
        .frame(maxWidth: .infinity)
    }
}

/// OAuth2 client credentials ile değeri alınan değişkenler. Token bellekte
/// tutulur, süresi dolunca bu değişkeni kullanan ilk istekten önce yenilenir.
private struct TokenVariablesEditor: View {
    @Environment(AppState.self) private var appState
    @Binding var environment: EnvironmentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Token değişkenleri (OAuth2 client credentials)")
                    .font(.headline)
                Spacer()
                Button {
                    environment.tokenVariables.append(TokenVariable(name: uniqueName()))
                } label: {
                    Label("Ekle", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            Text("İsteklerde {{isim}} olarak kullanılır. Token yalnızca bellekte tutulur; süresi dolunca onu kullanan istekten hemen önce yenisi alınır.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach($environment.tokenVariables) { $variable in
                        row($variable)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(10)
    }

    private func row(_ variable: Binding<TokenVariable>) -> some View {
        let value = variable.wrappedValue
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Değişken adı", text: variable.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Picker("", selection: variable.clientAuthentication) {
                    ForEach(TokenVariable.ClientAuthentication.allCases, id: \.self) { method in
                        Text(method.title).tag(method)
                    }
                }
                .frame(width: 140)
                .help("Client kimliği token adresine nasıl gönderilsin")
                Spacer()
                status(value)
                Button("Token Al") { fetch(value) }
                    .help("Ayarları denemek için şimdi yeni token al")
                Button(role: .destructive) {
                    appState.forgetToken(value, in: environment)
                    environment.tokenVariables.removeAll { $0.id == value.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            TextField("Token adresi, ör. https://auth.ornek.com/oauth/token", text: variable.tokenURL)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("Client ID", text: variable.clientID)
                    .textFieldStyle(.roundedBorder)
                TextField("Client secret, ör. {{secret:client_secret}}", text: variable.clientSecret)
                    .textFieldStyle(.roundedBorder)
                TextField("Scope (isteğe bağlı)", text: variable.scope)
                    .textFieldStyle(.roundedBorder)
            }
            warnings(value)
        }
        .padding(8)
        .background(Theme.editorBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func warnings(_ variable: TokenVariable) -> some View {
        let secret = variable.clientSecret.trimmingCharacters(in: .whitespaces)
        if !secret.isEmpty, !secret.contains("{{") {
            Label("Client secret düz metin; workspace dosyasına yazılır. Secrets'a ekleyip {{secret:isim}} ile referans ver.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.warning)
        }
        if environment.variables.contains(where: { $0.key == variable.trimmedName }) {
            Label("Aynı adlı bir değişken var; isteklerde token değişkeni kullanılır.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func status(_ variable: TokenVariable) -> some View {
        switch appState.tokenState(variable, in: environment) {
        case .fetching:
            ProgressView().controlSize(.small)
        case .valid(let expiresAt):
            Label(expiresAt.map { "geçerli, \($0.formatted(date: .omitted, time: .shortened))'e kadar" } ?? "geçerli",
                  systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.up)
        case .failed(let message):
            Label("alınamadı", systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(Theme.down)
                .help(message)
        case nil:
            EmptyView()
        }
    }

    private func fetch(_ variable: TokenVariable) {
        let snapshot = environment
        Task {
            _ = try? await appState.validToken(variable, in: snapshot, forceRefresh: true)
        }
    }

    private func uniqueName() -> String {
        let taken = Set(environment.tokenVariables.map(\.trimmedName))
        if !taken.contains("accessToken") { return "accessToken" }
        return (2...).lazy.map { "accessToken\($0)" }.first { !taken.contains($0) } ?? "accessToken"
    }
}
