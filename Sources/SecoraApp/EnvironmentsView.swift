import SwiftUI
import SecoraCore

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
        .frame(width: 640, height: 460)
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
        }
        .frame(maxWidth: .infinity)
    }
}
