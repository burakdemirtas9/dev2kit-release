import AppKit
import SwiftUI
import Dev2KitCore

/// `{{` yazıldığında environment değişkenlerini ve `secret:isim` girdilerini
/// öneren metin alanı. Öneriler alanın hemen altında satır içi listelenir
/// (popover odak çaldığı için kullanılmadı); tıklanınca `{{öneri}}` tamamlanır.
struct TemplateTextField: View {
    let placeholder: String
    @Binding var text: String
    /// Alanın uzunluk sınırı (`InputLimits`); varsayılan başlık değeri.
    /// `onSubmit`'ten ÖNCE: adres alanı Enter'ı sondaki kapanışla veriyor.
    var limit: InputLimits.Field = .headerValue
    /// Tablo hücresinde kenarlıksız (`KeyValueEditor`); tek başına alanda çerçeveli.
    var bordered = true
    var onSubmit: (() -> Void)?
    /// Verilirse alan kapsül içinde, solunda bu görünümle (adres çubuğu:
    /// metot seçici + adres, 2026-10-20). Öneri listesi kapsülün DIŞINDA,
    /// altında kalır.
    var capsuleLeading: AnyView?
    /// `true` olunca alan odak alır (ör. tanımsız değişkene tıklanınca
    /// Environment'lar penceresinde ilgili satırın değeri).
    var focusRequested = false

    @Environment(AppState.self) private var appState
    @FocusState private var isFocused: Bool
    /// Adres düzenleyicisi (kapsül) odakta mı; `TextField` odağından ayrı.
    @State private var isEditingAddress = false
    @State private var addressRejections = 0
    @State private var addressFocusRequest = 0
    @State private var popover = VariablePopoverPresenter()

    /// Son `{{`'den sonra henüz `}}` ile kapanmamış kısım; öneri tetiği.
    private var pendingToken: String? {
        guard let range = text.range(of: "{{", options: .backwards) else { return nil }
        let after = text[range.upperBound...]
        guard !after.contains("}}") else { return nil }
        return String(after)
    }

    private var suggestions: [String] {
        // Yalnızca odaktaki alanda öner: aksi halde başka alana geçince
        // yarım kalmış {{ yüzünden liste açık kalıyordu.
        guard isFocused || isEditingAddress, let token = pendingToken else { return [] }
        return appState.templateSuggestions(matching: token)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let capsuleLeading {
                // Üste hizalı: alan aşağı doğru büyürken metot seçici ve
                // ayraç ilk satırda kalır.
                HStack(alignment: .top, spacing: 0) {
                    capsuleLeading
                        .frame(height: URLEditor.lineHeight)
                    Divider()
                        .frame(height: 16)
                        .padding(.top, (URLEditor.lineHeight - 16) / 2)
                    addressEditor
                        .padding(.horizontal, 8)
                }
                .frame(minHeight: URLEditor.lineHeight)
                .inputChrome(cornerRadius: 8, isFocused: isEditingAddress)
                .inputLimitNotice(limit, trigger: addressRejections)
                // Boş durumdan yeni istek: adres alanı odakta açılır.
                .onAppear { if appState.takeAddressFocus() { addressFocusRequest += 1 } }
                .onChange(of: appState.addressFocusPending) { _, pending in
                    if pending, appState.takeAddressFocus() { addressFocusRequest += 1 }
                }
            } else if bordered {
                field
            } else {
                // Tablo hücresi: dinlenmede çerçevesiz, odakta lila zemin.
                field
                    .padding(.horizontal, Self.cellInset)
                    .padding(.vertical, 4)
                    .inputChrome(cornerRadius: 5, onlyWhenFocused: true, isFocused: isFocused)
            }
            suggestionList
                .padding(.horizontal, bordered ? 0 : Self.cellInset)
        }
        .onAppear { if focusRequested { requestFocus() } }
        .onChange(of: focusRequested) { _, requested in if requested { requestFocus() } }
    }

    /// Alanın kendisi (vurgu katmanıyla); kapsül ya da tek başına.
    private var field: some View {
        styled(TextField(placeholder, text: $text))
            .font(.system(.body, design: .monospaced))
            // Odak dışında metni vurgulu katman çizer (aşağıda); alanın
            // kendi yazısı saydam kalır, imleç ve seçim yine alanın.
            .foregroundStyle(showsHighlight ? AnyShapeStyle(.clear) : AnyShapeStyle(.primary))
            .autocorrectionDisabled()
            .focused($isFocused)
            .onSubmit { onSubmit?() }
            .inputLimit(limit)
            .overlay(alignment: .leading) {
                if showsHighlight {
                    VariableHighlight(text: text)
                        .padding(.leading, isBordered ? Self.borderedInset : Self.plainInset)
                }
            }
    }

    /// Kapsüldeki adres: tek satır ↔ odakta sarılı (`URLEditor`).
    private var addressEditor: some View {
        URLEditor(
            text: $text,
            isEditing: isEditingAddress,
            limit: limit.maxCharacters,
            definedVariables: Set(TemplateVariables.variableRanges(in: text).map(\.name).filter {
                appState.variablePreview(for: $0).isDefined
            }),
            onSubmit: { onSubmit?() },
            onEditingChange: { editing in
                // AppKit odak bildirimi düzen turunun içinde gelebilir.
                DispatchQueue.main.async { isEditingAddress = editing }
            },
            onLimitRejected: { addressRejections += 1 },
            onVariableClick: { name, rect, view in openVariable(name, at: rect, in: view) },
            focusRequest: addressFocusRequest
        )
        .overlay(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(height: URLEditor.lineHeight)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Değişkene tıklama: alandaki çiple aynı baloncuk. Tanımsızsa
    /// baloncukta "Environment değişkeni ekle" (pencere yalnızca o düğmeyle
    /// açılır, kullanıcı isteği 2026-10-20).
    private func openVariable(_ name: String, at rect: NSRect, in view: NSView) {
        popover.showVariable(name, appState: appState, at: rect, in: view)
    }

    @ViewBuilder
    private var suggestionList: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        complete(with: suggestion)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: suggestion.hasPrefix("secret:") ? "key.fill" : "curlybraces")
                                .font(.tinyText)
                                .foregroundStyle(Theme.purple)
                            Text(suggestion)
                                .font(.secondaryMono)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Theme.editorBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.purple.opacity(0.4))
            )
        }
    }

    /// Yazının alan kenarından uzaklığı (`.input` stiliyle aynı).
    static let borderedInset: CGFloat = InputFieldStyle.textInset
    /// Tablo hücresinde yazının hücre kenarına uzaklığı (`KeyValueEditor`'ün
    /// anahtar sütunuyla aynı).
    static let cellInset: CGFloat = 8
    static let plainInset: CGFloat = 0

    /// Kapsülde alanın kendi çerçevesi yok.
    private var isBordered: Bool { bordered && capsuleLeading == nil }

    /// Vurgu yalnızca odak dışında: yazarken alan olduğu gibi kalır.
    private var showsHighlight: Bool {
        !isFocused && TemplateVariables.containsVariable(text)
    }

    @ViewBuilder
    private func styled(_ field: TextField<Text>) -> some View {
        if isBordered {
            field.textFieldStyle(.input)
        } else {
            field.textFieldStyle(.plain)
        }
    }

    /// Bir sonraki turda: satır yeni göründüğünde alan henüz pencerede değil.
    private func requestFocus() {
        DispatchQueue.main.async { isFocused = true }
    }

    private func complete(with suggestion: String) {
        guard let range = text.range(of: "{{", options: .backwards) else { return }
        text = String(text[..<range.upperBound]) + suggestion + "}}"
        // Adres düzenleyicisinde odak öneri düğmesine kaymışsa geri gelsin.
        if capsuleLeading != nil { addressFocusRequest += 1 }
    }
}

/// Alandaki metnin `{{değişken}}` kısımları renkli ve tıklanabilir; tıklanınca
/// değeri baloncukta (environment ve Token Factory değeri kopyalanabilir;
/// secret değeri gösterilmez). Düz metin kısımları
/// tıklamayı alana bırakır (odak, imleç yeri).
private struct VariableHighlight: View {
    let text: String

    var body: some View {
        // Genişliği alan belirler (Color.clear önerilen genişliği alır),
        // metin doğal genişliğinde üstüne çizilip alan sınırında kırpılır.
        // Eskiden `fixedSize` metin dış çerçeveyi kendi genişliğine
        // büyütüyordu; `clipped` hiç kesmiyor, uzun adres komşu düğmelerin
        // üstüne taşıyordu.
        Color.clear
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(Array(TemplateVariables.segments(in: text).enumerated()), id: \.offset) { _, segment in
                        switch segment {
                        case .text(let plain):
                            Text(plain)
                                .foregroundStyle(.primary)
                                .allowsHitTesting(false)
                        case .variable(let raw, let name):
                            VariableChip(raw: raw, name: name)
                        }
                    }
                }
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .fixedSize()
            }
            .clipped()
    }
}

private struct VariableChip: View {
    let raw: String
    let name: String

    @Environment(AppState.self) private var appState
    @State private var showing = false

    var body: some View {
        let defined = appState.variablePreview(for: name).isDefined
        Text(raw)
            .foregroundStyle(defined ? Theme.variable : Theme.down)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill((defined ? Theme.variable : Theme.down).opacity(0.12))
            )
            .contentShape(Rectangle())
            .onTapGesture { showing = true }
            .help(defined ? L10n.t("variable.chip.help") : L10n.t("variable.chip.undefined"))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VariablePreviewCard(name: name, appState: appState) { showing = false }
            }
    }
}

struct VariablePreviewCard: View {
    let name: String
    let preview: TemplateVariables.Preview
    /// Token Factory değişkeninin bellekteki değeri (alınmadıysa `nil`).
    let token: TokenFactory.IssuedToken?
    /// Environment'lar penceresi: tanımsızsa "Environment değişkeni ekle"
    /// (taslakla), tanımlıysa "Environment'ta Aç" (satırında). Secret'larda yok.
    var openInEnvironments: (() -> Void)?
    /// Environment değişkeninin değerini yerinde kaydeder; hata metni döner.
    /// Yalnızca environment değişkeninde (Token Factory ve secret'ta yok).
    var saveValue: ((String) -> String?)?

    @State private var copied = false
    @State private var editing = false
    @State private var draft = ""
    /// Kayıttan sonra gösterilen değer (`preview` açılıştaki anlık görüntü).
    @State private var savedValue: String?
    @State private var saveError: String?
    @FocusState private var draftFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.secondaryMono.weight(.semibold))
            switch preview {
            case .environment(let environmentName, let value):
                let current = savedValue ?? value
                if editing {
                    editor(current)
                } else {
                    valueRow(current, editable: canEdit(current))
                }
                HStack(spacing: 12) {
                    source(L10n.t("variable.source.environment", environmentName.isEmpty ? L10n.t("common.unnamed") : environmentName))
                    if let openInEnvironments, !editing {
                        Spacer(minLength: 0)
                        Button(L10n.t("variable.openInEnvironments"), action: openInEnvironments)
                            .buttonStyle(.link)
                            .font(.secondaryText)
                            .help(L10n.t("variable.openInEnvironments.help"))
                    }
                }
            case .token(let requestName):
                if let token {
                    valueRow(token.value, editable: false)
                    source(token.needsRefresh() ? L10n.t("variable.source.tokenExpired", requestName) : L10n.t("variable.source.token", requestName))
                } else {
                    Text(L10n.t("variable.token.notFetched"))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    source(L10n.t("variable.source.tokenOnSend", requestName))
                }
            case .secret(let secret, let exists):
                if exists {
                    masked
                    source(L10n.t("variable.source.secret", secret))
                } else {
                    missing(L10n.t("variable.secret.undefined"))
                }
            case .undefined(let environmentName):
                missing(environmentName == nil
                        ? L10n.t("variable.noEnvironment")
                        : L10n.t("variable.undefined"))
                if let openInEnvironments {
                    Button(L10n.t("variable.define"), action: openInEnvironments)
                        .buttonStyle(PrimaryActionButtonStyle())
                        // Baloncuk anahtar pencere olunca ⏎ ile de çalışır.
                        .keyboardShortcut(.defaultAction)
                        .padding(.top, 2)
                        .help(environmentName.map { L10n.t("variable.define.help", $0) } ?? L10n.t("variable.define.choose"))
                }
            }
        }
        .padding(12)
    }

    /// Çok satırlı değer tek satırlık alanda düzenlenmez (satır sonları
    /// bozulmasın); onun için "Environment'ta Aç".
    private func canEdit(_ value: String) -> Bool {
        saveValue != nil && !value.contains(where: \.isNewline)
    }

    /// Değer + kopyala (kullanıcı isteği, 2026-10-20) + düzenle (2026-10-29).
    private func valueRow(_ value: String, editable: Bool) -> some View {
        // Simgeler değerin ilk satırıyla aynı hizada (çok satırlı değerde üstte).
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value.isEmpty ? L10n.t("variable.emptyValue") : value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .lineLimit(6)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: 360, alignment: .leading)
            if !value.isEmpty {
                Button {
                    // Değer token ya da kimlik bilgisi olabilir.
                    SensitivePasteboard.copy(value)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 14)
                        .iconHitTarget()
                }
                .buttonStyle(.borderless)
                .help(copied ? L10n.t("common.copied") : L10n.t("variable.copyValue"))
                .accessibilityLabel(L10n.t("variable.copyValue"))
            }
            if editable {
                Button {
                    startEditing(value)
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 14)
                        .iconHitTarget()
                }
                .buttonStyle(.borderless)
                .help(L10n.t("variable.edit"))
                .accessibilityLabel(L10n.t("variable.edit"))
            }
        }
    }

    /// Değer alanı: ⏎ kaydeder, Esc vazgeçer. Kaydet'e kadar hiçbir şey yazılmaz.
    private func editor(_ current: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L10n.t("environment.variable.value"), text: $draft)
                .inputLimit(.secretValue)
                .textFieldStyle(.input)
                .font(.system(.body, design: .monospaced))
                .frame(width: 360)
                .focused($draftFocused)
                .onSubmit { save(over: current) }
            if let saveError {
                Label(saveError, systemImage: MessageKind.error.symbol)
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(L10n.t("common.cancel")) {
                    editing = false
                    saveError = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.t("common.save")) { save(over: current) }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft == current)
            }
        }
    }

    private func startEditing(_ value: String) {
        draft = value
        saveError = nil
        editing = true
        DispatchQueue.main.async { draftFocused = true }
    }

    private func save(over current: String) {
        guard let saveValue, draft != current else {
            editing = false
            return
        }
        if let message = saveValue(draft) {
            saveError = message
            return
        }
        savedValue = draft
        copied = false
        editing = false
    }

    private var masked: some View {
        Text(L10n.t("variable.secret.masked"))
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    private func source(_ text: String) -> some View {
        Text(text).font(.secondaryText).foregroundStyle(.secondary)
    }

    private func missing(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.secondaryText)
            .foregroundStyle(Theme.down)
    }
}

extension VariablePreviewCard {
    /// Alanlar, adres ve gövde aynı kartı aynı eylemlerle gösterir. `close`
    /// baloncuğu kapatır (pencere açılmadan önce).
    ///
    /// Düzenleme yalnızca environment değişkeninde: Token Factory değeri
    /// Token Factory'nin, secret değeri Secrets ekranının işi. Değer,
    /// baloncuk açılırken etkin olan environment'a yazılır.
    @MainActor
    init(name: String, appState: AppState, close: @escaping () -> Void) {
        let preview = appState.variablePreview(for: name)
        let key = VariableDefinition.key(from: name)
        var saveValue: ((String) -> String?)?
        if case .environment = preview, let key, let environmentID = appState.activeEnvironment?.id {
            saveValue = { value in
                do {
                    try appState.updateVariable(key: key, value: value, environmentID: environmentID)
                    return nil
                } catch VariableDefinition.SaveError.missing {
                    return L10n.t("variable.edit.missing")
                } catch {
                    return error.localizedDescription
                }
            }
        }
        self.init(
            name: name,
            preview: preview,
            token: appState.cachedToken(forVariable: name),
            openInEnvironments: key == nil ? nil : {
                close()
                appState.defineVariable(name)
            },
            saveValue: saveValue
        )
    }
}

/// AppKit metin görünümündeki bir aralığa SwiftUI baloncuğu bağlar (adres
/// düzenleyicisinde değişkene tıklama). Baloncuk açıkken referansı tutar.
final class VariablePopoverPresenter {
    private var popover: NSPopover?

    /// Baloncuk anahtar pencere olur: içindeki düğmeye ⏎ ile, Esc ile
    /// kapatmaya klavyeden ulaşılır. Adres alanı ana pencerede ilk yanıtlayıcı
    /// kalır; alan daralmaz.
    func show<Content: View>(_ content: Content, at rect: NSRect, in view: NSView) {
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let host = NSHostingController(rootView: content)
        // Baloncuk içerikle büyüyüp küçülsün (değer düzenleme alanı açılınca).
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
        self.popover = popover
    }

    func close() {
        popover?.close()
        popover = nil
    }
}
