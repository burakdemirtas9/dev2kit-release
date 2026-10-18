import AppKit
import SwiftUI
import Dev2KitCore

/// Header ve query alanlarının düzenleyicisi: satır satır ya da toplu metin.
/// Toplu metnin çözümlenmesi Core'da (`KeyValueBulkCoder`), burada yalnızca
/// gösterim ve kullanıcıya dönen mesaj var.

struct KeyValueEditor: View {
    @Binding var entries: [KeyValueEntry]
    let keyPlaceholder: String
    let valuePlaceholder: String
    /// Değer alanının sınırı: başlık/parametre 8 KB, form ve environment daha büyük.
    var valueLimit: InputLimits.Field = .headerValue
    /// Anahtara göre satır notu: verilen satır soluklaşır ve yanında uyarı
    /// çıkar (ör. başlıklarda User-Agent: dev2kit kendi değerini gönderir).
    var keyNote: ((String) -> String?)? = nil

    @State private var isBulk = false
    @State private var bulkText = ""
    @State private var message: Message?
    /// Toplu moda girerken yapılan ilk `bulkText` atamasının entries'i
    /// gereksizce yeniden yazmasını engeller.
    @State private var suppressCommit = false

    private struct Message: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let message {
                Label(message.text, systemImage: message.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .font(.secondaryText)
                    .foregroundStyle(message.isError ? Theme.down : Theme.up)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
            if isBulk { bulkEditor } else { fieldEditor }
        }
    }

    private var toolbar: some View {
        HStack {
            Picker("", selection: $isBulk) {
                Text("Alanlar").tag(false)
                Text("Toplu Düzenle").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Button {
                validate()
            } label: {
                Label(
                    isBulk ? "Doğrula & Biçimlendir" : "Doğrula",
                    systemImage: isBulk ? "wand.and.stars" : "checkmark.seal"
                )
            }
            .help(isBulk
                  ? "Satırları denetle ve \"anahtar: değer\" biçimine getir"
                  : "Boş anahtar, tekrar eden anahtar gibi sorunları denetle")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onChange(of: isBulk) { _, nowBulk in
            message = nil
            if nowBulk {
                suppressCommit = true
                bulkText = KeyValueBulkCoder.encode(entries)
            } else {
                entries = KeyValueBulkCoder.decode(bulkText)
            }
        }
    }

    private var bulkEditor: some View {
        // Toplu metin de alanlarla aynı sınırlarda: en çok `maxRows` satır,
        // satır başına anahtar + değer kadar. Aşan yapıştırma girmez.
        CodeEditor(text: $bulkText, language: .plain, limits: EditorLimits(
            maxBytes: InputLimits.maxBulkBytes,
            maxLines: InputLimits.maxBulkLines,
            maxLineBytes: InputLimits.Field.key.maxCharacters + valueLimit.maxCharacters + 2,
            onRejected: { message = Message(text: $0.turkish, isError: true) },
            onLongLine: { _ in
                message = Message(text: "Eklenmedi: satır başına en çok \(InputLimits.Field.key.maxCharacters + valueLimit.maxCharacters) karakter.", isError: true)
            }
        ))
            .background(Theme.editorBackground)
            .overlay(alignment: .topLeading) {
                if bulkText.isEmpty {
                    Text("Content-Type: application/json\n//X-Devre-Disi: deger")
                        .foregroundStyle(.tertiary)
                        .font(.system(.body, design: .monospaced))
                        .padding(.top, 8).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: bulkText) {
                guard !suppressCommit else {
                    suppressCommit = false
                    return
                }
                // Canlı yazım: geçerli satırlar anında alanlara yansır,
                // yarım kalan satırlar sessizce atlanır.
                entries = KeyValueBulkCoder.decode(bulkText)
                message = nil
            }
    }

    // MARK: Tablo (Postman gibi)
    //
    // Kullanıcı geri bildirimi (2026-10-19): ayrı ayrı çerçeveli alanlarda
    // nereye yazılacağı anlaşılmıyordu. Sütun başlıkları, ızgara çizgileri,
    // kenarlıksız hücreler ve en altta her zaman boş bir "yeni satır":
    // yazmaya başlayınca satır kendiliğinden oluşur ("Satır Ekle" yok).

    /// En alttaki boş satır. Yazılınca AYNI kimlikle `entries`'e eklenir:
    /// görünüm kimliği değişmez, yazarken odak kaybolmaz.
    @State private var draft = KeyValueEntry()

    private static let checkWidth: CGFloat = 30
    private static let actionWidth: CGFloat = 30
    private static let rowHeight: CGFloat = 30

    /// Satırın verisi: dizideki yeri (taslakta `nil`). Gövdede bir kez, O(n).
    private struct RowRef: Identifiable {
        let id: UUID
        let index: Int?
    }

    private var fieldEditor: some View {
        GeometryReader { geometry in
            let keyWidth = max(140, (geometry.size.width - Self.checkWidth - Self.actionWidth) * 0.38)
            let rows = entries.indices.map { RowRef(id: entries[$0].id, index: $0) }
                + (entries.count < InputLimits.maxRows ? [RowRef(id: draft.id, index: nil)] : [])
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rows) { row in
                            tableRow(row, keyWidth: keyWidth)
                            Divider()
                        }
                    } header: {
                        tableHeader(keyWidth: keyWidth)
                    }
                }
                .overlay(alignment: .topLeading) { columnLines(keyWidth: keyWidth, totalWidth: geometry.size.width) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.tableLine))
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private func tableHeader(keyWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.checkWidth)
            Text("Anahtar").padding(.horizontal, 8).frame(width: keyWidth, alignment: .leading)
            Text("Değer").padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: Self.actionWidth)
        }
        .font(.secondaryText.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Sütun ayırıcıları tablo boyunca tek çizgi (satır başına çizmek yerine).
    private func columnLines(keyWidth: CGFloat, totalWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach([Self.checkWidth, Self.checkWidth + keyWidth, totalWidth - Self.actionWidth], id: \.self) { x in
                Rectangle().fill(Theme.tableLine).frame(width: 1).offset(x: x)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Taslak ve gerçek satır AYNI görünüm yapısında (yalnızca bağlama ve
    /// görünürlük farklı): taslak satıra dönüşünce odak korunur.
    private func tableRow(_ row: RowRef, keyWidth: CGFloat) -> some View {
        let isDraft = row.index == nil
        let note = entry(row).flatMap { keyNote?($0.key) }
        let enabled = isDraft || (entry(row)?.enabled != false && note == nil)
        return HStack(spacing: 0) {
            Toggle("", isOn: binding(row, \.enabled))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: Self.checkWidth)
                .opacity(isDraft ? 0 : 1)
                .disabled(isDraft)
                .help("Açık satırlar gönderilir")
            TextField(isDraft ? keyPlaceholder : "", text: binding(row, \.key))
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .inputLimit(.key)
                .padding(.horizontal, 8)
                .padding(.trailing, note == nil ? 0 : 18)
                .frame(width: keyWidth, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if let note {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                            .padding(.trailing, 6)
                            .help(note)
                            .accessibilityLabel(note)
                    }
                }
            TemplateTextField(placeholder: isDraft ? valuePlaceholder : "", text: binding(row, \.value),
                              limit: valueLimit, bordered: false)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                entries.removeAll { $0.id == row.id }
            } label: {
                Image(systemName: "trash").iconHitTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .frame(width: Self.actionWidth)
            .opacity(isDraft ? 0 : 1)
            .disabled(isDraft)
            .help("Satırı sil")
            .accessibilityLabel("Satırı sil")
        }
        .frame(minHeight: Self.rowHeight)
        .opacity(enabled ? 1 : 0.5)
        .contentShape(Rectangle())
    }

    private func entry(_ row: RowRef) -> KeyValueEntry? {
        guard let index = row.index, entries.indices.contains(index), entries[index].id == row.id else { return nil }
        return entries[index]
    }

    /// Satırın alanına bağlama. Taslakta bir şey yazılınca taslak (aynı
    /// kimlikle) diziye eklenir, yeni boş taslak açılır. Dizin bayatlamışsa
    /// (satır silinmiş) yazma yok sayılır: indeks bağlamasının çökmesi önlenir.
    private func binding<Value>(_ row: RowRef, _ field: WritableKeyPath<KeyValueEntry, Value>) -> Binding<Value> {
        Binding(
            get: { entry(row)?[keyPath: field] ?? draft[keyPath: field] },
            set: { newValue in
                if let index = row.index {
                    guard entries.indices.contains(index), entries[index].id == row.id else { return }
                    entries[index][keyPath: field] = newValue
                } else {
                    draft[keyPath: field] = newValue
                    if !draft.key.isEmpty || !draft.value.isEmpty, entries.count < InputLimits.maxRows {
                        entries.append(draft)
                        draft = KeyValueEntry()
                    }
                }
            }
        )
    }

    private func validate() {
        if isBulk {
            do {
                let formatted = try KeyValueBulkCoder.beautify(bulkText)
                suppressCommit = true
                bulkText = formatted
                entries = KeyValueBulkCoder.decode(formatted)
                let issues = KeyValueBulkCoder.validate(entries: entries)
                message = Message(
                    text: issues.isEmpty
                        ? "\(entries.count) alan geçerli."
                        : "Biçimlendirildi, ama: " + issues.map(\.message).joined(separator: " · "),
                    isError: false
                )
            } catch {
                message = Message(text: error.localizedDescription, isError: true)
            }
        } else {
            let issues = KeyValueBulkCoder.validate(entries: entries)
            message = issues.isEmpty
                ? Message(text: "\(entries.filter(\.enabled).count) etkin alan, sorun yok.", isError: false)
                : Message(
                    text: issues.prefix(3).map { "satır \($0.line): \($0.message)" }.joined(separator: " · "),
                    isError: true
                  )
        }
    }
}
