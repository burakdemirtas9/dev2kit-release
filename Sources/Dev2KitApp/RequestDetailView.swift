import AppKit
import SwiftUI
import Dev2KitCore

struct RequestDetailView: View {
    @Environment(AppState.self) private var appState
    @Binding var request: RequestModel
    @State private var showingCurl = false
    @State private var showingOptions = false
    @State private var showingRevertConfirm = false

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                requestBar
                Divider()
                editorTabs
            }
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity, alignment: .top)
            ResponseView()
                .frame(maxWidth: .infinity, minHeight: 160)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var requestBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $request.method) {
                ForEach(HTTPMethod.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .frame(width: 100)

            TemplateTextField(
                placeholder: "https://api.example.com/{{path}}",
                text: $request.url
            ) {
                appState.send(request)
            }

            if appState.isSending {
                Button {
                    appState.cancelSend(request.id)
                } label: {
                    Label("Durdur", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)
                .help("İsteği iptal et (⌘.)")
            } else {
                Button {
                    appState.send(request)
                } label: {
                    Label("Gönder", systemImage: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(request.url.isEmpty)
            }

            Button {
                showingOptions = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("İstek ayarları: zaman aşımı, yönlendirme, çerez")
            .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
                RequestOptionsPopover(options: $request.options)
            }

            Button {
                showingCurl = true
            } label: {
                Image(systemName: "terminal")
            }
            .help("cURL komutu olarak al")
            .disabled(request.url.isEmpty)
            .popover(isPresented: $showingCurl, arrowEdge: .bottom) {
                CurlPopover(request: request)
            }
        }
        .padding(10)
        .background(alignment: .topLeading) {
            // İstek adı düzenlenebilir başlık olarak üstte küçük durur.
            EmptyView()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                TextField("İstek adı", text: $request.name)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .fixedSize(horizontal: true, vertical: false)

                if appState.isDirty(request.id) {
                    Button {
                        showingRevertConfirm = true
                    } label: {
                        Label("son gönderilenden farklı", systemImage: "circle.fill")
                            .font(.caption)
                            .labelStyle(DirtyLabelStyle())
                    }
                    .buttonStyle(.plain)
                    .help("Bu istek en son gönderildiği halden farklı — tıklayıp o hale dönebilirsin")
                }

                Spacer()
                saveStatus
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .confirmationDialog(
            "Son gönderilen hale dönülsün mü?",
            isPresented: $showingRevertConfirm,
            titleVisibility: .visible
        ) {
            Button("Geri Dön", role: .destructive) {
                appState.revertToLastSent(request.id)
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Son gönderimden sonra yaptığın düzenlemeler silinecek. Bu işlem geri alınamaz.")
        }
    }

    /// Otomatik kaydın görünür hali.
    @ViewBuilder
    private var saveStatus: some View {
        switch appState.saveState {
        case .idle:
            EmptyView()
        case .pending:
            Label("Kaydediliyor…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .saved(let date):
            Label("Kaydedildi \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(Theme.down)
                .lineLimit(1)
        }
    }

    private var editorTabs: some View {
        @Bindable var state = appState
        // Açık sekme AppState'te: ⌘1…⌘4 menü komutları view @State'ine erişemez.
        return VStack(spacing: 0) {
            Picker("", selection: $state.editorTab) {
                ForEach(EditorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)

            switch appState.editorTab {
            case .headers:
                KeyValueEditor(entries: $request.headers, keyPlaceholder: "Header-Adi", valuePlaceholder: "değer veya {{secret:isim}}")
            case .body:
                BodyEditor(body: $request.body)
            case .auth:
                AuthEditor(auth: $request.auth)
            case .params:
                KeyValueEditor(entries: $request.queryParams, keyPlaceholder: "param", valuePlaceholder: "değer veya {{degisken}}")
            }
        }
    }
}

struct KeyValueEditor: View {
    @Binding var entries: [KeyValueEntry]
    let keyPlaceholder: String
    let valuePlaceholder: String

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
                    .font(.caption)
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
        CodeEditor(text: $bulkText, language: .plain)
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
                    TemplateTextField(placeholder: valuePlaceholder, text: $entry.value)
                    Button {
                        entries.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            Button {
                entries.append(KeyValueEntry())
            } label: {
                Label("Satır Ekle", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
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

struct BodyEditor: View {
    @Binding var body_: RequestBody
    @State private var formatError: String?
    /// Tip başına son içerik. Yalnızca bu istek görünürken yaşar; diske
    /// yazılmaz — kaydedilen gövde her zaman o an seçili olandır.
    @State private var drafts: [BodyKind: RequestBody] = [:]

    init(body: Binding<RequestBody>) {
        self._body_ = body
    }

    private enum BodyKind: String, CaseIterable {
        case none = "None"
        case formData = "Form Data"
        case urlEncoded = "x-www-form-urlencoded"
        case raw = "Raw"
    }

    /// Raw alt tipi; Content-Type başlığını belirler.
    private enum RawType: String, CaseIterable, Identifiable {
        case text = "Text"
        case json = "JSON"
        case xml = "XML"
        case html = "HTML"
        case javascript = "JavaScript"

        var id: String { rawValue }

        var contentType: String {
            switch self {
            case .text: return "text/plain"
            case .json: return "application/json"
            case .xml: return "application/xml"
            case .html: return "text/html"
            case .javascript: return "application/javascript"
            }
        }

        var codeLanguage: CodeLanguage {
            switch self {
            case .text: return .plain
            case .json: return .json
            case .xml, .html: return .markup
            case .javascript: return .javascript
            }
        }

        static func from(contentType: String) -> RawType {
            let lowered = contentType.lowercased()
            if lowered.contains("json") { return .json }
            if lowered.contains("xml") { return .xml }
            if lowered.contains("html") { return .html }
            if lowered.contains("javascript") { return .javascript }
            return .text
        }
    }

    /// Seçili gövde tipi. Ayrı bir hesaplanan özellik: binding'in setter'ı
    /// içinden getter'a erişmek özyineleme uyarısı üretiyordu.
    private var currentKind: BodyKind {
        switch body_ {
        case .none: return .none
        case .raw: return .raw
        case .formURLEncoded: return .urlEncoded
        case .multipartForm: return .formData
        }
    }

    private var kind: Binding<BodyKind> {
        Binding(
            get: { currentKind },
            set: { newKind in
                formatError = nil
                let current = currentKind
                guard newKind != current else { return }
                // Ayrılan tipin içeriğini sakla; geri dönüldüğünde yazdığın
                // JSON ya da doldurduğun alanlar kaybolmasın.
                drafts[current] = body_
                if let saved = drafts[newKind] {
                    body_ = saved
                    return
                }
                switch newKind {
                case .none: body_ = .none
                case .raw: body_ = .raw(content: "", contentType: RawType.json.contentType)
                case .urlEncoded: body_ = .formURLEncoded(fields: [])
                case .formData: body_ = .multipartForm(fields: [])
                }
            }
        )
    }

    private var rawType: Binding<RawType> {
        Binding(
            get: {
                if case .raw(_, let type) = body_ { return RawType.from(contentType: type) }
                return .json
            },
            set: {
                if case .raw(let content, _) = body_ {
                    body_ = .raw(content: content, contentType: $0.contentType)
                }
            }
        )
    }

    private var rawContent: Binding<String> {
        Binding(
            get: {
                if case .raw(let content, _) = body_ { return content }
                return ""
            },
            set: {
                if case .raw(_, let type) = body_ {
                    body_ = .raw(content: $0, contentType: type)
                }
            }
        )
    }

    private var formFields: Binding<[KeyValueEntry]> {
        Binding(
            get: {
                switch body_ {
                case .formURLEncoded(let fields), .multipartForm(let fields): return fields
                default: return []
                }
            },
            set: {
                switch body_ {
                case .formURLEncoded: body_ = .formURLEncoded(fields: $0)
                case .multipartForm: body_ = .multipartForm(fields: $0)
                default: break
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: kind) {
                    ForEach(BodyKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if case .raw = body_ {
                    Picker("", selection: rawType) {
                        ForEach(RawType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()

                    Spacer()
                    Button {
                        beautify()
                    } label: {
                        Label("Beautify", systemImage: "wand.and.stars")
                    }
                    .help(
                        rawType.wrappedValue == .text
                            ? "Düz metin biçimlendirilmez"
                            : "\(rawType.wrappedValue.rawValue) içeriğini biçimlendir"
                    )
                    .disabled(rawContent.wrappedValue.isEmpty || rawType.wrappedValue == .text)
                } else {
                    Spacer()
                }
            }
            if let formatError {
                Label(formatError, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.down)
                    .lineLimit(2)
            }

            switch body_ {
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
                CodeEditor(text: rawContent, language: rawType.wrappedValue.codeLanguage)
                    .background(Theme.editorBackground)
                    .overlay(alignment: .topLeading) {
                        if rawContent.wrappedValue.isEmpty {
                            Text("{ \"ornek\": \"{{degisken}} destekler\" }")
                                .foregroundStyle(.tertiary)
                                .font(.system(.body, design: .monospaced))
                                .padding(.top, 8).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: rawContent.wrappedValue) {
                        formatError = nil
                    }
            case .formURLEncoded, .multipartForm:
                KeyValueEditor(
                    entries: formFields,
                    keyPlaceholder: "alan",
                    valuePlaceholder: "değer veya {{degisken}}"
                )
            }
        }
        .padding(10)
    }

    /// Seçili raw tipine göre ilgili biçimlendiriciyi çalıştırır.
    private func beautify() {
        do {
            let source = rawContent.wrappedValue
            let formatted: String
            switch rawType.wrappedValue {
            case .json:
                formatted = try JSONFormatter.beautify(source)
            case .xml:
                formatted = try MarkupFormatter.beautify(source, flavor: .xml)
            case .html:
                formatted = try MarkupFormatter.beautify(source, flavor: .html)
            case .javascript:
                formatted = try ScriptFormatter.beautify(source)
            case .text:
                return
            }
            rawContent.wrappedValue = formatted
            formatError = nil
        } catch {
            var message = error.localizedDescription
            let curlyQuotes: Set<Character> = ["\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"]
            if rawContent.wrappedValue.contains(where: { curlyQuotes.contains($0) }) {
                message += " — metinde kıvrık tırnak (\u{201C} \u{201D}) var, düz tırnak (\") olmalı."
            }
            formatError = message
        }
    }
}

struct AuthEditor: View {
    @Binding var auth: AuthConfig

    private enum AuthKind: String, CaseIterable {
        case none = "Yok", basic = "Basic", bearer = "Bearer", apiKey = "API Key", oauth2 = "OAuth2"
    }

    private var kind: Binding<AuthKind> {
        Binding(
            get: {
                switch auth {
                case .none: return .none
                case .basic: return .basic
                case .bearer: return .bearer
                case .apiKey: return .apiKey
                case .oauth2: return .oauth2
                }
            },
            set: {
                switch $0 {
                case .none: auth = .none
                case .basic: auth = .basic(username: "", password: "")
                case .bearer: auth = .bearer(token: "")
                case .apiKey: auth = .apiKey(key: "X-Api-Key", value: "", location: .header)
                case .oauth2: auth = .oauth2(OAuth2Config())
                }
            }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Sol sütun: auth türü dropdown'ı (Postman yerleşimi)
            VStack(alignment: .leading, spacing: 6) {
                Text("Auth Türü")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: kind) {
                    ForEach(AuthKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 140, alignment: .leading)
            }
            .padding(12)

            Divider()

            // Sağ sütun: seçilen türün alanları
            VStack(alignment: .leading, spacing: 10) {
                switch auth {
                case .none:
                    Text("Bu istek kimlik doğrulama kullanmıyor.")
                        .foregroundStyle(.secondary)
                case .basic(let username, let password):
                    authField("Kullanıcı Adı", placeholder: "kullanıcı adı", text: Binding(
                        get: { username },
                        set: { auth = .basic(username: $0, password: password) }
                    ))
                    authField("Şifre", placeholder: "{{secret:isim}}", text: Binding(
                        get: { password },
                        set: { auth = .basic(username: username, password: $0) }
                    ))
                case .bearer(let token):
                    authField("Token", placeholder: "{{secret:isim}}", text: Binding(
                        get: { token },
                        set: { auth = .bearer(token: $0) }
                    ))
                case .apiKey(let key, let value, let location):
                    authField("Key", placeholder: "X-Api-Key", text: Binding(
                        get: { key },
                        set: { auth = .apiKey(key: $0, value: value, location: location) }
                    ))
                    authField("Değer", placeholder: "{{secret:isim}}", text: Binding(
                        get: { value },
                        set: { auth = .apiKey(key: key, value: $0, location: location) }
                    ))
                    HStack {
                        fieldLabel("Konum")
                        Picker("", selection: Binding(
                            get: { location },
                            set: { auth = .apiKey(key: key, value: value, location: $0) }
                        )) {
                            Text("Header").tag(AuthConfig.APIKeyLocation.header)
                            Text("Query Param").tag(AuthConfig.APIKeyLocation.queryParam)
                        }
                        .labelsHidden()
                        .frame(width: 160, alignment: .leading)
                    }
                case .oauth2(let oauthConfig):
                    OAuth2Editor(config: Binding(
                        get: { oauthConfig },
                        set: { auth = .oauth2($0) }
                    ))
                }

                if kind.wrappedValue != .none, kind.wrappedValue != .oauth2 {
                    Label(
                        "Düz metin secret yazma: değeri Secrets'a ekleyip {{secret:isim}} olarak referans ver — {{ yazınca öneriler açılır.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .frame(width: 110, alignment: .trailing)
            .foregroundStyle(.secondary)
    }

    private func authField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(alignment: .top) {
            fieldLabel(title)
                .padding(.top, 3)
            TemplateTextField(placeholder: placeholder, text: text)
        }
    }
}

/// İsteği cURL komutu olarak gösterip panoya kopyalatan popover.
/// Varsayılanda secret'lar {{secret:isim}} olarak bırakılır; kullanıcı
/// bilerek işaretlerse gerçek değerler çözülür.
struct CurlPopover: View {
    @Environment(AppState.self) private var appState
    let request: RequestModel
    @State private var includeSecrets = false
    @State private var copied = false

    private var curlText: String {
        appState.curlCommand(for: request, includeSecrets: includeSecrets)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("cURL Komutu")
                .font(.headline)

            ScrollView {
                Text(curlText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(width: 540, height: 180)
            .background(Theme.editorBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Toggle("Secret değerlerini çöz", isOn: $includeSecrets)
                .toggleStyle(.checkbox)
            if includeSecrets {
                Label("Dikkat: kopyalanan komut gerçek secret değerlerini içerecek.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }

            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(curlText, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Kopyalandı" : "Kopyala",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
        }
        .padding(14)
        .onChange(of: includeSecrets) {
            copied = false
        }
    }
}

/// İstek başına ağ ayarları: zaman aşımı, yönlendirme politikası, çerez.
struct RequestOptionsPopover: View {
    @Binding var options: RequestOptions

    var body: some View {
        Form {
            Section("Zaman Aşımı") {
                HStack {
                    TextField("", value: $options.timeout, format: .number)
                        .frame(width: 60)
                    Stepper("saniye", value: $options.timeout, in: RequestOptions.timeoutRange, step: 5)
                }
            }

            Section("Yönlendirme") {
                Toggle("Yönlendirmeleri izle", isOn: $options.redirect.follow)
                if options.redirect.follow {
                    Stepper(
                        "En fazla \(options.redirect.maxRedirects) yönlendirme",
                        value: $options.redirect.maxRedirects,
                        in: 1...20
                    )
                    Toggle("https → http düşüşüne izin ver", isOn: $options.redirect.allowInsecureDowngrade)
                    if options.redirect.allowInsecureDowngrade {
                        Label(
                            "Trafik şifresiz hale gelebilir; yalnızca bilinçli test için aç.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                    }
                    Label(
                        "Farklı bir host'a yönlendirmede Authorization ve Cookie başlıkları otomatik düşürülür.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Çerezler") {
                Toggle("Oturum çerezlerini kullan", isOn: $options.sendCookies)
                Label(
                    "Çerezler yalnızca bellekte ve environment başına ayrı tutulur; diske yazılmaz.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .frame(maxHeight: 480)
    }
}


/// Nokta + metin: "değişti" işaretini sade tutar.
private struct DirtyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(.system(size: 7))
                .foregroundStyle(Theme.warning)
            configuration.title
                .foregroundStyle(.secondary)
        }
    }
}

/// OAuth2 yapılandırması ve yetkilendirme akışı.
struct OAuth2Editor: View {
    @Environment(AppState.self) private var appState
    @Binding var config: OAuth2Config

    private var token: OAuth2Token? { appState.storedToken(for: config) }
    private var isAuthorizing: Bool { appState.authorizingConfigID == config.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            tokenStatus

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                row("Authorization URL", "https://idp.example.com/authorize", $config.authorizationURL)
                row("Token URL", "https://idp.example.com/token", $config.tokenURL)
                row("Client ID", "istemci kimliği", $config.clientID)
                row("Client Secret", "boş bırak veya {{secret:isim}}", $config.clientSecret)
                row("Scopes", "openid profile email", $config.scopes)
            }

            HStack {
                Button {
                    appState.authorize(config)
                } label: {
                    if isAuthorizing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Tarayıcı bekleniyor…")
                        }
                    } else {
                        Label(token == nil ? "Yetkilendir" : "Yeniden Yetkilendir", systemImage: "person.badge.key")
                    }
                }
                .disabled(isAuthorizing || config.authorizationURL.isEmpty || config.clientID.isEmpty)

                if token != nil {
                    Button(role: .destructive) {
                        appState.clearToken(for: config)
                    } label: {
                        Label("Token'ı Sil", systemImage: "trash")
                    }
                    .disabled(isAuthorizing)
                }
            }

            if let message = appState.authMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.contains("tamamlandı") ? Theme.up : Theme.down)
                    .lineLimit(3)
            }

            Label(
                "Sistem tarayıcısı kullanılır; uygulama parolanı hiç görmez. Token şifreli vault'ta saklanır, koleksiyon dosyasına yazılmaz. Yönlendirme yalnızca 127.0.0.1'e bağlanır.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var tokenStatus: some View {
        if let token {
            HStack(spacing: 6) {
                Image(systemName: token.isExpired() ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(token.isExpired() ? Theme.warning : Theme.up)
                if let expiry = token.expiresAt {
                    Text(token.isExpired()
                         ? "Token süresi doldu — gönderimde otomatik yenilenecek"
                         : "Token geçerli · \(expiry.formatted(date: .omitted, time: .shortened))'a kadar")
                } else {
                    Text("Token var (süre bilgisi yok)")
                }
                if token.refreshToken != nil {
                    Text("· yenilenebilir").foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
        } else {
            Label("Henüz token yok", systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        GridRow {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            TemplateTextField(placeholder: placeholder, text: text)
        }
    }
}
