import AppKit
import SwiftUI
import Dev2KitCore

/// İstek gövdesi düzenleyicisi: tip seçimi, raw içerik ve form alanları.
///
/// Kurallar burada DEĞİL, Core'da ve testli: gövde tipleri ve alan erişimi
/// `BodyKind`/`RequestBody` uzantısında, tip değiştirirken taslak saklama
/// `BodyDrafts`'ta, biçimlendirme `Beautifier`'da. Bu dosyada yalnızca
/// gösterim ve kullanıcıya dönen mesaj var.
struct BodyEditor: View {
    @Environment(AppState.self) private var appState
    @Binding var body_: RequestBody
    @State private var formatError: String?
    /// Tip başına son içerik. Yalnızca bu istek görünürken yaşar; diske
    /// yazılmaz — kaydedilen gövde her zaman o an seçili olandır.
    @State private var drafts = BodyDrafts()
    @StateObject private var folding = CodeFoldingController()
    /// Gövdenin KENDİ araması; yanıttaki aramadan bağımsızdır.
    @StateObject private var search = EditorSearchController()

    init(body: Binding<RequestBody>) {
        self._body_ = body
    }

    // MARK: - Arayüz adları
    //
    // Core'daki tipler davranışı tanımlar, görünen adı değil. Kullanıcıya
    // gösterilen metin burada durur ki lokalizasyon da tek yerden yapılabilsin.

    private static func label(_ kind: BodyKind) -> String {
        switch kind {
        case .none: return "None"
        case .formData: return "Form Data"
        case .urlEncoded: return "x-www-form-urlencoded"
        case .raw: return "Raw"
        }
    }

    private static func label(_ kind: Beautifier.Kind) -> String {
        switch kind {
        case .plain: return "Text"
        case .json: return "JSON"
        case .xml: return "XML"
        case .html: return "HTML"
        case .javascript: return "JavaScript"
        case .css: return "CSS"
        case .sql: return "SQL"
        case .markdown: return "Markdown"
        }
    }

    // MARK: - Bağlantılar
    //
    // Her binding tek satır: okuma ve yazma kuralı `RequestBody` uzantısında.

    private var kind: Binding<BodyKind> {
        Binding(
            get: { body_.kind },
            set: { newKind in
                formatError = nil
                body_ = drafts.switching(body_, to: newKind)
            }
        )
    }

    private var rawKind: Binding<Beautifier.Kind> {
        Binding(
            get: { Beautifier.kind(contentType: body_.rawContentType) },
            set: { body_ = body_.settingRawContentType($0.contentType) }
        )
    }

    private var rawContent: Binding<String> {
        Binding(get: { body_.rawContent }, set: { body_ = body_.settingRawContent($0) })
    }

    private var formFields: Binding<[KeyValueEntry]> {
        Binding(get: { body_.formFields }, set: { body_ = body_.settingFormFields($0) })
    }

    // MARK: - Görünüm

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            toolbar
            if let formatError {
                Label(formatError, systemImage: "xmark.octagon.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
                    .lineLimit(2)
            }
            // Ayraç: gutter ile üstündeki segmentli denetim aynı x'te başlıyor
            // ve aynı griyi taşıyor; arada çizgi olmayınca göz ikisini tek bir
            // şerit olarak okuyup "satır numarası alanı araç çubuğuna taşmış"
            // gibi görüyordu.
            Divider()
            if search.isPresented, body_.kind == .raw, !bodyHiddenFromEditor {
                EditorSearchBar(search: search)
            }
            editor
        }
        .padding(10)
        .onChange(of: body_.kind) {
            // Raw dışındaki tiplerde aranacak metin editörü yok.
            if body_.kind != .raw { search.close() }
        }
        .onChange(of: appState.bodySearchRequest) {
            // Menüdeki "Gövdede Ara" (⌥⌘F).
            guard body_.kind == .raw else { return }
            search.open()
        }
    }

    private var toolbar: some View {
        HStack {
            Picker("", selection: kind) {
                ForEach(BodyKind.allCases) { Text(Self.label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if body_.kind == .raw {
                Picker("", selection: rawKind) {
                    ForEach(Beautifier.Kind.allCases, id: \.self) { Text(Self.label($0)).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()

                Spacer()
                // Gizli gövdede (editör yok) arayacak/katlayacak bir şey yok.
                if !bodyHiddenFromEditor {
                    SearchToggleButton(search: search)
                    FoldButtons(folding: folding)
                }
                beautifyButton
            } else {
                Spacer()
            }
        }
    }

    private var beautifyButton: some View {
        let kind = rawKind.wrappedValue
        let isPlain = kind == .plain
        return Button {
            beautify()
        } label: {
            Label("Beautify", systemImage: "wand.and.stars")
        }
        .help(isPlain ? "Düz metin biçimlendirilmez" : "\(Self.label(kind)) içeriğini biçimlendir")
        .disabled(rawContent.wrappedValue.isEmpty || isPlain)
    }

    @ViewBuilder
    private var editor: some View {
        switch body_.kind {
        case .none:
            // Üstteki VStack leading hizalı olduğu için boş durum ekranı
            // kendi genişliğinde sola yapışıyordu; alanı doldurup ortalanır.
            ContentUnavailableView(
                "Body yok",
                systemImage: "square.dashed",
                description: Text("Bu istek body içermiyor.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .raw:
            if bodyHiddenFromEditor {
                OversizedTextNotice(
                    title: "Gövde editörde gösterilmiyor: \(TextStats.size(body_.rawContent.utf8.count))",
                    detail: "\(TextStats.size(WorkbenchLimits.maxInputBytes))'tan büyük ya da \(TextStats.size(WorkbenchLimits.maxEditorLineBytes))'tan uzun satırlı metin (sıkıştırılmış JSON tek satırdır) editörde dev2kit'i dondurur. Gövde saklanır ve olduğu gibi gönderilir; biçimlendirirsen editörde açılır."
                ) {
                    Button("Biçimlendir") { beautify() }
                        .controlSize(.small)
                        .disabled(rawKind.wrappedValue == .plain)
                    CopyButton(text: body_.rawContent, help: "Gövdeyi kopyala")
                    Button("Temizle") { rawContent.wrappedValue = "" }
                        .controlSize(.small)
                }
                .background(Theme.editorBackground)
            } else {
                CodeEditor(
                    text: rawContent,
                    language: CodeLanguage(rawKind.wrappedValue),
                    folding: folding,
                    search: search,
                    limits: EditorLimits(
                        onRejected: { formatError = $0.turkish },
                        onLongLine: { rawContent.wrappedValue = $0 }
                    )
                )
                    .background(Theme.editorBackground)
                    .overlay(alignment: .topLeading) {
                        if rawContent.wrappedValue.isEmpty {
                            Text("{ \"ornek\": \"{{degisken}} destekler\" }")
                                .foregroundStyle(.tertiary)
                                .font(.system(.body, design: .monospaced))
                                // Şeridin altında kalmasın: genişliği editör bildiriyor.
                                .padding(.top, 8)
                                .padding(.leading, folding.gutterWidth + 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: rawContent.wrappedValue) { formatError = nil }
            }
        case .urlEncoded, .formData:
            KeyValueEditor(
                entries: formFields,
                keyPlaceholder: "alan",
                valuePlaceholder: "değer veya {{degisken}}",
                valueLimit: .formValue
            )
        }
    }

    /// Gövde editörde gösterilemeyecek kadar büyük ya da uzun satırlı mı
    /// (`WorkbenchLimits`, Workbench girdisiyle aynı kural). 1 MB'ın altında
    /// hiç taranmaz: her render'da yapılıyor.
    private var bodyHiddenFromEditor: Bool {
        let text = body_.rawContent
        return text.utf8.count > WorkbenchLimits.maxEditorLineBytes && WorkbenchLimits.isTooLargeForEditor(text)
    }

    /// Seçili raw tipine göre biçimlendirir; hata kullanıcıya gösterilir.
    private func beautify() {
        do {
            rawContent.wrappedValue = try Beautifier.beautify(rawContent.wrappedValue, as: rawKind.wrappedValue)
            formatError = nil
        } catch {
            formatError = Self.message(for: error, source: rawContent.wrappedValue)
        }
    }

    /// Kıvrık tırnak en sık rastlanan sebep: metin bir yerden kopyalanmış.
    private static func message(for error: Error, source: String) -> String {
        let curlyQuotes: Set<Character> = ["\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"]
        guard source.contains(where: { curlyQuotes.contains($0) }) else {
            return error.localizedDescription
        }
        return error.localizedDescription
            + " — metinde kıvrık tırnak (\u{201C} \u{201D}) var, düz tırnak (\") olmalı."
    }
}
