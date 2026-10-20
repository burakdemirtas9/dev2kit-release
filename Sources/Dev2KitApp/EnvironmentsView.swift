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
            Text(L10n.t("toolbar.environments"))
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
                                        .help(L10n.t("environment.active"))
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
                        L10n.t("environment.select.title"),
                        systemImage: "globe",
                        description: Text(L10n.t("common.selectOrCreate"))
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(minHeight: 320)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

            HStack {
                Spacer()
                Button(L10n.t("common.close")) { dismiss() }
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
            ? (.warning, L10n.t("environment.variable.disabled", key))
            : nil
        return true
    }

    private func save(_ draft: VariableDraft) -> String? {
        do {
            let id = try appState.saveVariable(key: draft.key, value: draft.value, environmentID: draft.environmentID)
            self.draft = nil
            selectedID = id
            notice = (.success, L10n.t("environment.variable.saved", draft.key.trimmingCharacters(in: .whitespaces)))
            return nil
        } catch VariableDefinition.SaveError.duplicate {
            return L10n.t("environment.variable.duplicate")
        } catch VariableDefinition.SaveError.emptyKey {
            return L10n.t("environment.variable.emptyName")
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
                Text(L10n.t("environment.variable.new")).fontWeight(.semibold)
                Text(subtitle)
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                TextField(L10n.t("environment.variable.name"), text: $draft.key)
                    .inputLimit(.key)
                    .textFieldStyle(.input)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 220)
                TextField(L10n.t("environment.variable.value"), text: $draft.value)
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
                        Text(L10n.t("common.choose")).tag(UUID?.none)
                    }
                    ForEach(environments) { environment in
                        Text(environment.name.isEmpty ? L10n.t("common.unnamed") : environment.name).tag(UUID?.some(environment.id))
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
                Button(L10n.t("common.cancel"), action: onCancel)
                Button(L10n.t("common.save"), action: save)
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
            return L10n.t("environment.variable.chooseTarget")
        }
        if environments.isEmpty {
            return L10n.t("environment.variable.willCreate")
        }
        let name = environments.first { $0.id == draft.environmentID }?.name ?? ""
        return L10n.t("environment.variable.target", name.isEmpty ? L10n.t("common.unnamed") : name)
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
                TextField(L10n.t("environment.name.placeholder"), text: $environment.name)
                    .inputLimit(.name)
                    .textFieldStyle(.input)
                    .font(.headline)
                if isActive {
                    Label(L10n.t("environment.isActive"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.up)
                        .font(.secondaryText)
                } else {
                    Button(L10n.t("environment.makeActive"), action: makeActive)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            Text(L10n.t("environment.variables.help"))
                .font(.secondaryText)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)

            KeyValueEditor(
                entries: $environment.variables,
                keyPlaceholder: L10n.t("environment.key.placeholder"),
                valuePlaceholder: L10n.t("environment.value.placeholder"),
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
            Label(L10n.t("environment.tokenVariables"), systemImage: "key.viewfinder")
                .font(.headline)
            if sources.isEmpty {
                Text(L10n.t("environment.tokenVariables.empty"))
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
                            Label(L10n.t("environment.tokenVariables.shadows"), systemImage: "exclamationmark.triangle.fill")
                                .font(.secondaryText)
                                .foregroundStyle(Theme.warning)
                                .help(L10n.t("environment.tokenVariables.shadows.help", source.variable))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}
