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

    @Environment(AppState.self) private var appState
    @FocusState private var isFocused: Bool

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
        guard isFocused, let token = pendingToken else { return [] }
        return appState.templateSuggestions(matching: token)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let capsuleLeading {
                HStack(spacing: 0) {
                    capsuleLeading
                    Divider().frame(height: 16)
                    field.padding(.horizontal, 8)
                }
                .frame(height: 28)
                .background(Theme.editorBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isFocused ? Theme.accent.opacity(0.8) : Color(nsColor: .separatorColor),
                                      lineWidth: isFocused ? 1.5 : 1)
                )
            } else {
                field
            }
            suggestionList
        }
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

    /// Yazının alan kenarından uzaklığı (ekran dışında çizilip ölçüldü).
    static let borderedInset: CGFloat = 6
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
            field.textFieldStyle(.roundedBorder)
        } else {
            field.textFieldStyle(.plain)
        }
    }

    private func complete(with suggestion: String) {
        guard let range = text.range(of: "{{", options: .backwards) else { return }
        text = String(text[..<range.upperBound]) + suggestion + "}}"
    }
}

/// Alandaki metnin `{{değişken}}` kısımları renkli ve tıklanabilir; tıklanınca
/// değeri baloncukta (environment ve Token Factory değeri kopyalanabilir;
/// secret değeri gösterilmez). Düz metin kısımları
/// tıklamayı alana bırakır (odak, imleç yeri).
private struct VariableHighlight: View {
    let text: String

    var body: some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .help(defined ? "Değeri görmek için tıkla" : "Tanımsız değişken")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VariablePreviewCard(
                    name: name,
                    preview: appState.variablePreview(for: name),
                    token: appState.cachedToken(forVariable: name)
                )
            }
    }
}

struct VariablePreviewCard: View {
    let name: String
    let preview: TemplateVariables.Preview
    /// Token Factory değişkeninin bellekteki değeri (alınmadıysa `nil`).
    let token: TokenFactory.IssuedToken?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.secondaryMono.weight(.semibold))
            switch preview {
            case .environment(let environmentName, let value):
                valueRow(value)
                source("Environment: \(environmentName.isEmpty ? "adsız" : environmentName)")
            case .token(let requestName):
                if let token {
                    valueRow(token.value)
                    source("Token Factory: \(requestName)" + (token.needsRefresh() ? ". Süresi dolmuş, gönderimde yenilenir." : ""))
                } else {
                    Text("Henüz alınmadı")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    source("Token Factory: \(requestName). Gönderimde alınır.")
                }
            case .secret(let secret, let exists):
                if exists {
                    masked
                    source("Secret (Keychain): \(secret)")
                } else {
                    missing("Tanımsız secret. Secrets ekranından ekleyebilirsin.")
                }
            case .undefined(let environmentName):
                missing(environmentName.map { "\"\($0)\" environment'ında tanımlı değil." }
                        ?? "Environment seçili değil.")
            }
        }
        .padding(12)
    }

    /// Değer + kopyala (kullanıcı isteği, 2026-10-20).
    private func valueRow(_ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(value.isEmpty ? "(boş)" : value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .lineLimit(6)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: 360, alignment: .leading)
            if !value.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 14)
                }
                .buttonStyle(.borderless)
                .help(copied ? "Kopyalandı" : "Değeri kopyala")
            }
        }
    }

    private var masked: some View {
        Text("••••••••  değer gösterilmez")
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
