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

    private var fieldEditor: some View {
        List {
            ForEach($entries) { $entry in
                HStack {
                    Toggle("", isOn: $entry.enabled).labelsHidden()
                    TextField(keyPlaceholder, text: $entry.key)
                        .font(.system(.body, design: .monospaced))
                        .inputLimit(.key)
                    TemplateTextField(placeholder: valuePlaceholder, text: $entry.value, limit: valueLimit)
                    Button {
                        entries.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .iconHitTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            Button {
                entries.append(KeyValueEntry())
            } label: {
                Label(entries.count >= InputLimits.maxRows ? InputLimits.tooManyRowsMessage : "Satır Ekle", systemImage: "plus")
                    .font(.secondaryText)
                    .rowHitTarget(minHeight: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(entries.count >= InputLimits.maxRows)
        }
        .listStyle(.inset)
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
