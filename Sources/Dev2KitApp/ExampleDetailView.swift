import SwiftUI
import Dev2KitCore

/// Kayıtlı bir response örneği: üstte örneğin request'i, altta response'u.
/// İkisi de düzenlenebilir (Postman'deki gibi) ve istek düzenlemesi gibi
/// kendiliğinden kaydedilir. Ana isteği değiştirmez; buradan hiçbir şey
/// gönderilmez: Gönder yerine "Dene" ana isteğe döner.
///
/// Response varsayılan olarak canlı yanıtla aynı görünümde (`ResponseView`:
/// önizleme, arama, katlama); "Düzenle" ile status, body ve header
/// editörlerine geçer.
struct ExampleDetailView: View {
    @Environment(AppState.self) private var appState
    let request: RequestModel
    let example: ResponseExample
    @Binding var draft: ResponseExample

    /// Biçimlendirilmiş hali; canlı yanıttaki gibi arka planda bir kez.
    @State private var display: AppState.ResponseDisplay?
    @State private var displayedExampleID: UUID?
    @State private var requestTab: EditorTab = .params
    @State private var editingResponse = false
    @State private var responseTab: ResponseEditTab = .body
    @State private var bodyRejection: String?

    enum ResponseEditTab: CaseIterable { case body, headers }

    private var ref: AppState.ExampleRef {
        AppState.ExampleRef(requestID: request.id, exampleID: example.id)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                titleRow
                controlsRow
                banner
                Divider()
                requestEditors
                    .frame(height: max(150, geometry.size.height * 0.36))
                Divider()
                responseHeader
                Divider()
                responsePane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Yeniden adlandırma body'yi değiştirmez; gösterim yalnızca içerik
        // değişince yeniden hazırlanır.
        .task(id: DisplayKey(example)) {
            let data = example.responseData
            let prepared = await BackgroundWork.run { AppState.makeDisplay(data) }
            guard !Task.isCancelled else { return }
            display = prepared
            displayedExampleID = example.id
        }
        .onChange(of: example.id) {
            editingResponse = false
            bodyRejection = nil
        }
    }

    private struct DisplayKey: Equatable {
        let id: UUID
        let statusCode: Int
        let headers: [ResponseExample.Header]
        let body: String

        init(_ example: ResponseExample) {
            id = example.id
            statusCode = example.statusCode
            headers = example.headers
            body = example.body
        }
    }

    // MARK: - Başlık

    private var titleRow: some View {
        HStack(spacing: 8) {
            // Ad ve bağlı istek yan yana, sola yaslı; uzun ad kısalır (genişlik
            // içerikten istenmez, pencere asgari ölçüsü büyümesin).
            HStack(spacing: 8) {
                Text(ResponseExamples.badge)
                    .font(.secondaryMono)
                    .foregroundStyle(.secondary)
                Text(example.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(example.name)
                    .layoutPriority(1)
                Text(L10n.t("example.parent", request.name))
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            iconButton("pencil", help: L10n.t("example.rename.title")) { appState.exampleRenameTarget = ref }
            iconButton("trash", help: L10n.t("example.delete.help")) { appState.exampleDeleteTarget = ref }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .iconHitTarget()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Request

    /// Örneğin request'i; yoksa (özellik öncesi örnek) `nil`.
    private var requestModel: Binding<RequestModel>? {
        guard draft.request != nil else { return nil }
        return Binding(
            get: { (draft.request ?? ExampleRequest()).asRequestModel },
            set: { model in
                var updated = draft.request ?? ExampleRequest()
                let before = updated
                updated.update(from: model)
                // Adres ↔ Params eşitlemesi: istek editöründeki kuralın
                // (QueryParamSync) aynısı, beklemeden.
                if updated.url != before.url {
                    let synced = QueryParamSync.afterURLEdit(urlBefore: before.url, url: updated.url, params: updated.queryParams)
                    updated.url = synced.url
                    updated.queryParams = synced.params
                } else if updated.queryParams != before.queryParams {
                    let synced = QueryParamSync.afterParamsEdit(url: updated.url, paramsBefore: before.queryParams, params: updated.queryParams)
                    updated.url = synced.url
                    updated.queryParams = synced.params
                }
                draft.request = updated
            }
        )
    }

    /// Metot + adres; gönder yerine "Dene" (isteğe döner, göndermez).
    private var controlsRow: some View {
        HStack(alignment: .top, spacing: 8) {
            if let model = requestModel {
                TemplateTextField(
                    placeholder: "https://api.example.com/{{path}}",
                    text: model.url,
                    limit: .url,
                    onSubmit: {},
                    capsuleLeading: AnyView(
                        MethodPicker(selection: model.method, bordered: false)
                            .frame(width: 92)
                            .padding(.leading, 4)
                    )
                )
            } else {
                HStack(spacing: 8) {
                    Text(request.method.rawValue)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.color(for: request.method))
                        .frame(width: 56, alignment: .leading)
                        .padding(.leading, 10)
                    Text(request.url.isEmpty ? " " : request.url)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 28)
                .inputChrome(isFocused: false)
            }

            Button {
                appState.returnFromExample()
            } label: {
                Label(L10n.t("example.try"), systemImage: "arrow.uturn.backward")
                    .padding(.horizontal, 6)
                    .frame(height: 28)
            }
            .buttonStyle(PrimaryActionButtonStyle())
            // Gönder'in kısayolu burada isteğe döner; gönderim yapmaz.
            .keyboardShortcut(KeyboardShortcut(.return, modifiers: .command), onlyIn: .apiClient)
            .help(L10n.t("example.try.help"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var banner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            MessageIcon(kind: .info)
            Text(L10n.t("example.banner.title")).fontWeight(.semibold)
            Text(L10n.t("example.banner.detail", L10n.date(example.savedAt)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MessageKind.info.background)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var requestEditors: some View {
        if let model = requestModel {
            VStack(spacing: 0) {
                HStack {
                    EditorTabPicker(
                        selection: $requestTab,
                        tabs: [.params, .headers, .body],
                        marked: model.wrappedValue.body.hasContent ? [.body] : [],
                        counts: [.headers: model.wrappedValue.activeHeaderCount, .params: model.wrappedValue.activeQueryParamCount]
                    )
                    Spacer()
                    Text(L10n.t("example.request.masked"))
                        .font(.tinyText)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
                switch requestTab {
                case .headers:
                    KeyValueEditor(entries: model.headers,
                                   keyPlaceholder: L10n.t("headers.key.placeholder"),
                                   valuePlaceholder: L10n.t("headers.value.placeholder"))
                case .body:
                    BodyEditor(body: model.body)
                default:
                    KeyValueEditor(entries: model.queryParams,
                                   keyPlaceholder: L10n.t("query.key.placeholder"),
                                   valuePlaceholder: L10n.t("query.value.placeholder"))
                }
            }
        } else {
            VStack(spacing: 10) {
                Text(L10n.t("example.request.missing"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.t("example.request.add")) {
                    // Boş başlar; uydurma değer konmaz (metot ana istekten).
                    draft.request = ExampleRequest(method: request.method)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Response

    private var responseHeader: some View {
        HStack(spacing: 8) {
            Text(L10n.t("example.response.title"))
                .font(.secondaryText.weight(.semibold))
                .foregroundStyle(.secondary)
            if editingResponse {
                Text(L10n.t("example.status"))
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                TextField(L10n.t("example.status.placeholder"), text: statusText)
                    .inputLimit(.short)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 56)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .inputChrome()
                ForEach(ResponseEditTab.allCases, id: \.self) { tab in
                    chip(tab == .body ? L10n.t("example.tab.body") : L10n.t("example.tab.headers"),
                         selected: responseTab == tab) { responseTab = tab }
                }
            }
            Spacer()
            Button(editingResponse ? L10n.t("example.edit.done") : L10n.t("example.edit")) {
                editingResponse.toggle()
                bodyRejection = nil
            }
            .help(L10n.t("example.edit.help"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .fontWeight(selected ? .medium : .regular)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 24)
                .background { if selected { SelectedChip() } }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Status yalnızca rakam; boş ya da geçersizse "bilinmiyor" (—).
    private var statusText: Binding<String> {
        Binding(
            get: { draft.statusCode > 0 ? String(draft.statusCode) : "" },
            set: { text in
                let digits = String(text.filter(\.isNumber).prefix(3))
                draft.statusCode = Int(digits) ?? ResponseExamples.unknownStatus
            }
        )
    }

    @ViewBuilder
    private var responsePane: some View {
        if editingResponse {
            switch responseTab {
            case .body: responseBodyEditor
            case .headers:
                KeyValueEditor(entries: responseHeaders,
                               keyPlaceholder: L10n.t("headers.key.placeholder"),
                               valuePlaceholder: L10n.t("headers.value.placeholder"))
            }
        } else if let display, displayedExampleID == example.id {
            ResponseView(exampleDisplay: display)
                // Başka örneğe geçince sekme/arama durumu sıfırlansın.
                .id(example.id)
        } else {
            ProgressView(L10n.t("example.preparing"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var responseBodyEditor: some View {
        if draft.bodyEncoding == .base64 {
            ContentUnavailableView(
                L10n.t("example.body.binary", draft.contentType ?? "application/octet-stream"),
                systemImage: "doc.badge.ellipsis"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if let bodyRejection {
                    HStack(spacing: 6) {
                        MessageIcon(kind: .warning)
                        Text(bodyRejection).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .font(.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(MessageKind.warning.background)
                }
                CodeEditor(
                    text: $draft.body,
                    language: CodeLanguage(Beautifier.kind(contentType: draft.contentType ?? "", body: draft.body)),
                    isEditable: true,
                    // Örnek body sınırı (`ResponseExamples.maxBodyBytes`) yazarken de.
                    limits: EditorLimits(
                        maxBytes: ResponseExamples.maxBodyBytes,
                        maxDisplayBytes: ResponseExamples.maxBodyBytes,
                        onRejected: { bodyRejection = $0.localized },
                        onLongLine: { _ in bodyRejection = WorkbenchLimits.Rejection.longLineEdit.localized }
                    )
                )
                .background(Theme.editorBackground)
            }
        }
    }

    /// Response header'ları tablo satırlarına; kimlik ve açık/kapalı korunur.
    private var responseHeaders: Binding<[KeyValueEntry]> {
        Binding(
            get: { draft.headers.map { KeyValueEntry(id: $0.id, key: $0.name, value: $0.value, enabled: $0.enabled) } },
            set: { entries in
                draft.headers = entries.map { ResponseExample.Header(id: $0.id, name: $0.key, value: $0.value, enabled: $0.enabled) }
            }
        )
    }
}
