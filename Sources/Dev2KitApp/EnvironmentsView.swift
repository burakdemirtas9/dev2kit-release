import SwiftUI
import Dev2KitCore

/// Environment oluşturma/düzenleme ekranı: solda environment listesi,
/// sağda seçilenin adı ve değişkenleri.
struct EnvironmentsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    /// Tanımsız değişkenden gelindiyse: henüz kaydedilmemiş yeni değişken.
    @State private var draft: VariableDraft?
    /// Değişken zaten varsa gidilecek satır.
    @State private var focusEntryID: UUID?
    /// Satır var ama kapalı ya da az önce kaydedildi: kullanıcıya not.
    @State private var notice: (kind: MessageKind, text: String)?

    var body: some View {
        @Bindable var state = appState
        VStack(alignment: .leading, spacing: 12) {
            Text("Environment'lar")
                .font(.title2).bold()

            if let draft {
                VariableDraftCard(
                    draft: Binding(get: { draft }, set: { self.draft = $0 }),
                    environments: appState.workspace.environments,
                    onEnvironmentChange: { environmentID in
                        if let environmentID { selectedID = environmentID }
                        // Seçilen environment'ta bu ad zaten varsa oraya gidilir;
                        // mevcut değerin üzerine yeni satır açılmaz.
                        openExistingIfPresent(key: draft.key, in: environmentID)
                    },
                    onSave: save,
                    onCancel: { self.draft = nil }
                )
            } else if let notice {
                Label(notice.text, systemImage: notice.kind.symbol)
                    .font(.secondaryText)
                    .foregroundStyle(notice.kind.tint)
            }

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
                    EnvironmentDetail(environment: binding, isActive: appState.workspace.activeEnvironmentID == selectedID,
                                      focusEntryID: focusEntryID) {
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
            if let request = appState.takeVariableDefinitionRequest() {
                start(request)
            }
        }
        // Pencere açıkken başka bir tanımsız değişkene tıklanırsa.
        .onChange(of: appState.environmentsRequest) {
            if let request = appState.takeVariableDefinitionRequest() {
                start(request)
            }
        }
    }

    private func start(_ request: AppState.VariableDefinitionRequest) {
        draft = nil
        focusEntryID = nil
        notice = nil
        switch request.target {
        case .environment(let id):
            selectedID = id
            if !openExistingIfPresent(key: request.key, in: id) {
                draft = VariableDraft(key: request.key, environmentID: id, mustChoose: false)
            }
        case .choose:
            draft = VariableDraft(key: request.key, environmentID: nil, mustChoose: true)
        case .createNew:
            draft = VariableDraft(key: request.key, environmentID: nil, mustChoose: false)
        }
    }

    /// Değişken environment'ta varsa satırına gider (taslak kapanır).
    @discardableResult
    private func openExistingIfPresent(key: String, in environmentID: UUID?) -> Bool {
        guard let environmentID,
              let environment = appState.workspace.environments.first(where: { $0.id == environmentID }),
              case .existing(let entryID, let isDisabled) = VariableDefinition.plan(for: key, in: environment)
        else { return false }
        draft = nil
        selectedID = environmentID
        focusEntryID = entryID
        notice = isDisabled
            ? (.warning, "{{\(key)}} bu environment'ta var ama satırı kapalı; işaretleyince kullanılır.")
            : nil
        return true
    }

    private func save(_ draft: VariableDraft) -> String? {
        do {
            let id = try appState.saveVariable(key: draft.key, value: draft.value, environmentID: draft.environmentID)
            self.draft = nil
            selectedID = id
            notice = (.success, "{{\(draft.key.trimmingCharacters(in: .whitespaces))}} kaydedildi; istekte artık çözülüyor.")
            return nil
        } catch VariableDefinition.SaveError.duplicate {
            return "Bu environment'ta bu adla bir değişken zaten var."
        } catch VariableDefinition.SaveError.emptyKey {
            return "Değişken adı boş olamaz."
        } catch {
            return error.localizedDescription
        }
    }
}

/// Kaydedilmemiş yeni değişken.
struct VariableDraft: Equatable {
    var key: String
    var value = ""
    /// `nil`: seçilmedi (`mustChoose`) ya da hiç environment yok (yenisi oluşur).
    var environmentID: UUID?
    let mustChoose: Bool
}

/// Tanımsız değişkene değer verme kartı: anahtar dolu, imleç değerde.
/// Kaydet'e basılana kadar hiçbir şey yazılmaz.
private struct VariableDraftCard: View {
    @Binding var draft: VariableDraft
    let environments: [EnvironmentModel]
    let onEnvironmentChange: (UUID?) -> Void
    let onSave: (VariableDraft) -> String?
    let onCancel: () -> Void

    @FocusState private var valueFocused: Bool
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                MessageIcon(kind: .info)
                Text("Yeni değişken").fontWeight(.semibold)
                Text(subtitle)
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                TextField("isim", text: $draft.key)
                    .inputLimit(.key)
                    .textFieldStyle(.input)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 220)
                TextField("değer", text: $draft.value)
                    .inputLimit(.secretValue)
                    .textFieldStyle(.input)
                    .font(.system(.body, design: .monospaced))
                    .focused($valueFocused)
                    .onSubmit(save)
            }
            if environments.count > 1 || draft.mustChoose {
                Picker("Environment", selection: Binding(
                    get: { draft.environmentID },
                    set: { newValue in
                        draft.environmentID = newValue
                        error = nil
                        onEnvironmentChange(newValue)
                    }
                )) {
                    if draft.environmentID == nil {
                        Text("Seç…").tag(UUID?.none)
                    }
                    ForEach(environments) { environment in
                        Text(environment.name.isEmpty ? "adsız" : environment.name).tag(UUID?.some(environment.id))
                    }
                }
                .frame(maxWidth: 320)
            }
            if let error {
                Label(error, systemImage: MessageKind.error.symbol)
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
            }
            HStack {
                Spacer()
                Button("Vazgeç", action: onCancel)
                Button("Kaydet", action: save)
                    .buttonStyle(PrimaryActionButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(12)
        .background(MessageKind.info.background, in: RoundedRectangle(cornerRadius: 8))
        .onAppear { DispatchQueue.main.async { valueFocused = true } }
    }

    private var subtitle: String {
        if draft.mustChoose && draft.environmentID == nil {
            return "Etkin environment yok; hangisine ekleneceğini seç."
        }
        if environments.isEmpty {
            return "Henüz environment yok; kaydedince “Environment” oluşturulup etkin yapılır."
        }
        let name = environments.first { $0.id == draft.environmentID }?.name ?? ""
        return "“\(name.isEmpty ? "adsız" : name)” environment'ına eklenecek."
    }

    private var canSave: Bool {
        !draft.key.trimmingCharacters(in: .whitespaces).isEmpty && !(draft.mustChoose && draft.environmentID == nil)
    }

    private func save() {
        guard canSave else { return }
        error = onSave(draft)
    }
}

private struct EnvironmentDetail: View {
    @Binding var environment: EnvironmentModel
    let isActive: Bool
    var focusEntryID: UUID?
    let makeActive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Environment adı", text: $environment.name)
                    .inputLimit(.name)
                    .textFieldStyle(.input)
                    .font(.headline)
                if isActive {
                    Label("Aktif", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.up)
                        .font(.secondaryText)
                } else {
                    Button("Aktif Yap", action: makeActive)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            Text("Değişkenler — isteklerde {{isim}} olarak kullanılır. Secret değerleri buraya değil Secrets'a yaz.")
                .font(.secondaryText)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)

            KeyValueEditor(
                entries: $environment.variables,
                keyPlaceholder: "isim (ör: baseUrl)",
                valuePlaceholder: "değer (ör: https://api.example.com)",
                valueLimit: .secretValue,
                focusEntryID: focusEntryID
            )

            Divider()
            TokenFactoryVariablesNote(environment: environment)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Bu environment'ta Token Factory'den gelen değişkenler. Salt okunur:
/// token işlemlerinin hepsi Token Factory'de yapılır, burada yalnızca neyin
/// nereden geldiği ve hangi environment değişkenini ezdiği görünür.
private struct TokenFactoryVariablesNote: View {
    @Environment(AppState.self) private var appState
    let environment: EnvironmentModel

    var body: some View {
        let sources = appState.tokenSources(for: environment)
        let shadowed = Set(TokenFactory.shadowedVariables(in: environment, sources: sources))
        VStack(alignment: .leading, spacing: 6) {
            Label("Token Factory'den gelen değişkenler", systemImage: "key.viewfinder")
                .font(.headline)
            if sources.isEmpty {
                Text("Bu environment'ta Token Factory değişkeni yok. Sol panelin altındaki Token Factory'den ekleyebilirsin.")
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sources, id: \.request.id) { source in
                    HStack(spacing: 6) {
                        Text("{{\(source.variable)}}")
                            .font(.secondaryMono)
                        Text("← \(source.request.name)")
                            .font(.secondaryText)
                            .foregroundStyle(.secondary)
                        if shadowed.contains(source.variable) {
                            Label("aynı adlı değişkeni ezer", systemImage: "exclamationmark.triangle.fill")
                                .font(.secondaryText)
                                .foregroundStyle(Theme.warning)
                                .help("Bu environment'ta \(source.variable) adlı bir değişken de var; isteklerde Token Factory'deki token kullanılır.")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}
