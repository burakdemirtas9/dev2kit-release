import SwiftUI
import Dev2KitCore

/// Şifreli vault'taki secret'ları yönetir. Değerler listede asla gösterilmez;
/// yalnızca isimler listelenir, değer girişi tek yönlüdür (yaz ama okuma).
struct SecretsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var names: [String] = []
    @State private var newName = ""
    @State private var newValue = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Secrets")
                .font(.title2).bold()
            Text("Değerler AES-GCM ile şifrelenmiş yerel vault'ta saklanır; koleksiyon dosyalarına asla düz metin yazılmaz. İsteklerde {{secret:isim}} olarak kullan.")
                .font(.secondaryText)
                .foregroundStyle(.secondary)

            List {
                ForEach(names, id: \.self) { name in
                    HStack {
                        Image(systemName: "key.fill").foregroundStyle(.secondary)
                        Text(name).font(.system(.body, design: .monospaced))
                        Spacer()
                        Text("••••••••").foregroundStyle(.tertiary)
                        Button(role: .destructive) {
                            delete(name)
                        } label: {
                            Image(systemName: "trash")
                                .iconHitTarget()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 160)

            HStack {
                TextField("isim (ör: github_token)", text: $newName)
                    .font(.system(.body, design: .monospaced))
                SecureField("değer", text: $newValue)
                Button("Ekle") { add() }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newValue.isEmpty)
            }
            .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.secondaryText)
            }

            HStack {
                Spacer()
                Button("Kapat") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: reload)
    }

    private func reload() {
        names = appState.secretNames
        errorMessage = nil
    }

    private func add() {
        do {
            try appState.secretStore.setSecret(newValue, forName: newName.trimmingCharacters(in: .whitespaces))
            appState.invalidateSecretNames()
            newName = ""
            newValue = ""
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ name: String) {
        do {
            try appState.secretStore.deleteSecret(forName: name)
            appState.invalidateSecretNames()
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
