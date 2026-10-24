import AppKit
import SwiftUI
import Dev2KitCore

struct ResponseView: View {
    @Environment(AppState.self) private var appState
    /// Verilirse canlı yanıt yerine kayıtlı örnek gösterilir: aynı body,
    /// header ve önizleme görünümleri; ölçüm (süre, ağ, yönlendirme),
    /// token önerileri ve "örnek olarak kaydet" yok.
    var exampleDisplay: AppState.ResponseDisplay?

    private var isExample: Bool { exampleDisplay != nil }

    private var state: AppState.ResponseState {
        exampleDisplay.map { .success($0) } ?? appState.lastResponse
    }
    @State private var selectedTab: Tab = .body
    @State private var copied = false
    @State private var fileSaveError: String?
    @State private var showingNetwork = false
    @State private var showingTiming = false
    @State private var showingSize = false
    @State private var copiedCorrelationID = false
    @State private var hoveringCorrelationID = false
    /// Başlıklar listesinde az önce kopyalanan satır (aynı ad birden çok
    /// kez gelebildiği için sıra numarası).
    @State private var copiedHeaderIndex: Int?
    @StateObject private var folding = CodeFoldingController()
    /// Yanıtta tıklanan yer (satır, sütun): alt bilgide (Workbench ile ortak).
    @State private var cursor: (line: Int, column: Int)?
    /// Yanıtın KENDİ araması; istek gövdesindeki aramadan bağımsızdır.
    @StateObject private var search = EditorSearchController()

    enum Tab: String, CaseIterable {
        case body = "Body"
        case preview = "Önizleme"
        case headers = "Headers"
        case redirects = "Yönlendirme"

        /// Görünen ad (seçili dilde). `rawValue` sabit kimlik.
        var title: String {
            switch self {
            case .body: return "Body"
            case .preview: return L10n.t("response.tab.preview")
            case .headers: return "Headers"
            case .redirects: return L10n.t("response.tab.redirects")
            }
        }
    }

    var body: some View {
        switch state {
        case .idle:
            ContentUnavailableView(
                L10n.t("response.empty.title"),
                systemImage: "arrow.down.circle",
                description: Text(L10n.t("response.empty.message"))
            )
        case .loading:
            ProgressView(L10n.t("response.sending"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failure(let message):
            VStack(spacing: 12) {
                ContentUnavailableView(
                    L10n.t("response.failed"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                if let id = appState.selectedRequestID, let variables = appState.tokenBlockedSends[id] {
                    SendWithoutTokenButton(requestID: id, variables: variables)
                }
                if let suggestion = appState.tlsSuggestion {
                    TLSSuggestionBanner(match: suggestion)
                        .frame(maxWidth: 520)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
            }
        case .blocked(let findings):
            securityReview(
                findings,
                title: L10n.t("response.blocked.title"),
                subtitle: L10n.t("response.blocked.subtitle"),
                icon: "xmark.shield.fill",
                tint: Theme.down
            )
        case .needsApproval(let findings):
            securityReview(
                findings,
                title: L10n.t("response.stopped.title"),
                subtitle: L10n.t("response.stopped.subtitle"),
                icon: "exclamationmark.shield.fill",
                tint: Theme.warning
            ) {
                HStack {
                    Spacer()
                    Button(L10n.t("common.cancel"), role: .cancel) {
                        appState.dismissSecurityReview()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(L10n.t("response.sendAnyway")) {
                        appState.approveAndSend(findings)
                    }
                }
            }
        case .success(let display):
            let response = display.data
            VStack(spacing: 0) {
                statusBar(display)
                // Uygulamanın gönderme davranışı hakkında bildirim; sunucu
                // yanıtına eklenmez. Yanıtla (o gönderimle) birlikte gelir,
                // başka istek/yanıtta görünmez.
                if response.requestBodyOmitted {
                    HStack(spacing: 6) {
                        MessageIcon(kind: .warning)
                        Text(L10n.t("response.getBodyOmitted"))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .font(.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(MessageKind.warning.background)
                    .help(L10n.t("response.getBodyOmitted.help"))
                    .accessibilityElement(children: .combine)
                }
                if !isExample, let id = appState.selectedRequestID, let advice = appState.tokenRetryAdvice[id] {
                    TokenRetryBanner(requestID: id, advice: advice)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                // Sekmeler istek sekmeleriyle aynı dilde: sola yaslı, seçili
                // olan camlı (2026-10-20). Arama ve katlama sağda, yalnızca
                // gövde sekmesinde.
                HStack(spacing: 2) {
                    ForEach(availableTabs(display), id: \.self) { tab in
                        responseTabButton(tab, title: tab == .redirects ? "\(tab.title) (\(L10n.number(response.redirects.count)))" : tab.title)
                    }
                    Spacer()
                    if selectedTab == .body {
                        SearchToggleButton(search: search)
                        FoldButtons(folding: folding)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                Divider()

                switch selectedTab {
                case .body:
                    if isExample, response.body.isEmpty {
                        ContentUnavailableView(L10n.t("example.emptyBody"), systemImage: "doc")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.editorBackground)
                    } else if !display.fitsEditor {
                        OversizedTextNotice(
                            title: L10n.t("response.hidden.title", TextStats.size(display.prettyText.utf8.count)),
                            detail: L10n.t("response.hidden.detail", TextStats.size(WorkbenchLimits.maxOutputBytes), TextStats.size(WorkbenchLimits.maxEditorLineBytes))
                        ) {
                            CopyButton(text: display.prettyText, help: L10n.t("response.copyBody"))
                        }
                        .background(Theme.editorBackground)
                    } else {
                        if search.isPresented {
                            EditorSearchBar(search: search)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 6)
                        }
                        CodeEditor(
                            text: .constant(display.prettyText),
                            language: display.language,
                            isEditable: false,
                            folding: folding,
                            search: search,
                            paneIdentifier: AppState.CodeEditorPane.response.rawValue,
                            onCursorChange: { cursor = ($0, $1) }
                        )
                        .background(Theme.editorBackground)
                        EditorFooter {
                            if let cursor, !display.prettyText.isEmpty {
                                Text(L10n.t("editor.cursor", L10n.number(cursor.line), L10n.number(cursor.column)))
                            }
                        } trailing: {
                            Text(display.stats.summary)
                        }
                    }
                case .preview:
                    if let previewKind = display.previewKind {
                        ResponsePreviewView(
                            kind: previewKind,
                            payload: response.body,
                            // HAM metin: biçimlendirilmiş HTML'de eklenen
                            // girinti <pre> gibi boşluğa duyarlı içeriği bozar.
                            text: response.bodyText
                        )
                    }
                case .headers:
                    // Aynı başlık birden çok kez gelebilir (Set-Cookie);
                    // id olarak isim kullanmak SwiftUI'da çakışma yaratıyordu.
                    List(Array(response.headers.enumerated()), id: \.offset) { index, header in
                        HStack(alignment: .top) {
                            Text(header.name)
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.semibold)
                                .frame(width: 220, alignment: .leading)
                            // Uzun değer sarılır; kopyala düğmesi sabit genişlikte
                            // sağda kalır, metnin üstüne binmez.
                            Text(header.value)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            headerCopyButton(index: index, name: header.name, value: header.value)
                        }
                    }
                    .listStyle(.inset)
                case .redirects:
                    redirectList(response)
                }
            }
            .onChange(of: display.data.finalURL) {
                // Yeni yanıtta o sekmenin karşılığı yoksa boşta kalmasın.
                let redirectsGone = selectedTab == .redirects
                    && response.redirects.isEmpty && response.redirectStop == nil
                let previewGone = selectedTab == .preview && display.previewKind == nil
                if redirectsGone || previewGone {
                    selectedTab = .body
                }
            }
            .onChange(of: appState.responseSearchRequest) {
                // Menüdeki "Yanıtta Ara" (⇧⌘F). Arama gövdede yapıldığı için
                // başka sekmedeysek oraya geçilir.
                selectedTab = .body
                search.open()
            }
            .onChange(of: selectedTab) {
                // Başlık/yönlendirme sekmesinde aranacak editör yok; çubuk
                // açık kalırsa hiçbir şey yapmayan bir kutu gibi görünür.
                if selectedTab != .body { search.close() }
            }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
            .task(id: copiedHeaderIndex) {
                guard copiedHeaderIndex != nil else { return }
                try? await Task.sleep(for: .seconds(1.5))
                copiedHeaderIndex = nil
            }
            .task(id: copiedCorrelationID) {
                guard copiedCorrelationID else { return }
                try? await Task.sleep(for: .seconds(1.5))
                copiedCorrelationID = false
            }
            .alert(
                L10n.t("response.saveFailed.title"),
                isPresented: Binding(
                    get: { fileSaveError != nil },
                    set: { if !$0 { fileSaveError = nil } }
                )
            ) {
                Button(L10n.t("common.ok")) { fileSaveError = nil }
            } message: {
                Text(L10n.t("response.saveFailed.message", fileSaveError ?? ""))
            }
        }
    }

    /// Güvenlik bulgularının listesi. Onay düğmeleri yalnızca uyarılarda
    /// verilir; kesin engelde kullanıcıya geçersiz kılma yolu sunulmaz.
    private func securityReview(
        _ findings: [SecurityFinding],
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        @ViewBuilder actions: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.title3.bold())
                .foregroundStyle(tint)
            Text(subtitle)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(findings) { finding in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(finding.title).fontWeight(.semibold)
                            Text(finding.detail)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            actions()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Yönlendirme zinciri: her adımda nereye gidildiği ve hangi hassas
    /// başlıkların düşürüldüğü denetim izi olarak gösterilir.
    private func redirectList(_ response: ResponseData) -> some View {
        List {
            ForEach(Array(response.redirects.enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                        Text("\(step.statusCode)")
                            .font(.secondaryMono).bold()
                            .foregroundStyle(Theme.warning)
                        Text(step.to.absoluteString)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if !step.strippedHeaders.isEmpty {
                        Label(
                            L10n.t("response.redirect.stripped", step.strippedHeaders.joined(separator: ", ")),
                            systemImage: "lock.shield.fill"
                        )
                        .font(.secondaryText)
                        .foregroundStyle(Theme.up)
                    }
                }
                .padding(.vertical, 2)
            }
            if let stop = response.redirectStop {
                Label(L10n.t("response.redirect.chainStopped", stop.explanation), systemImage: "hand.raised.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
            }
            if let final = response.finalURL {
                Label(L10n.t("response.redirect.finalURL", final.absoluteString), systemImage: "flag.checkered")
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .listStyle(.inset)
    }

    /// İzleme kimliği rozeti: başlığın ADI görünür (ör. X-B3-TraceId),
    /// tıklayınca yalnızca DEĞERİ kopyalanır — log sistemine (Kibana) bu
    /// değerle gidiliyor (kullanıcı isteği, 2026-10-20; eskiden "# değer").
    /// Pano kuralı bozulmuyor: kopyalama yalnızca kullanıcı tıklayınca olur.
    private func correlationBadge(_ correlation: CorrelationID.Match) -> some View {
        Button {
            copyToPasteboard(correlation.value)
            copiedCorrelationID = true
        } label: {
            HStack(spacing: 4) {
                if copiedCorrelationID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.up)
                } else if hoveringCorrelationID {
                    Image(systemName: "doc.on.doc")
                }
                Text(copiedCorrelationID ? L10n.t("common.copied") : correlation.headerName)
                    .font(.secondaryMono)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(hoveringCorrelationID ? 0.25 : 0.15), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hoveringCorrelationID = $0 }
        .help(L10n.t("variable.copyValue"))
        .accessibilityLabel(L10n.t("response.correlation.copy", correlation.headerName))
        .accessibilityHint(correlation.explanation)
    }

    /// Başlıklar listesinde satırın kopyala düğmesi: `ad: değer`, yalnızca o
    /// satır. Kopyalanınca kısa süre onay işareti.
    private func headerCopyButton(index: Int, name: String, value: String) -> some View {
        let copiedThis = copiedHeaderIndex == index
        return Button {
            copyToPasteboard(ResponseHeaderCopy.line(name: name, value: value))
            copiedHeaderIndex = index
        } label: {
            Image(systemName: copiedThis ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copiedThis ? AnyShapeStyle(Theme.up) : AnyShapeStyle(.secondary))
                .iconHitTarget(20)
        }
        .buttonStyle(.plain)
        .help(copiedThis ? L10n.t("common.copied") : L10n.t("response.header.copyLine", name))
        .accessibilityLabel(copiedThis ? L10n.t("common.copied") : L10n.t("response.header.copy", name))
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Gösterilecek sekmeler: yönlendirme zinciri yoksa "Yönlendirme",
    /// önizlenecek bir şey yoksa (JSON, düz metin) "Önizleme" yok.
    private func availableTabs(_ display: AppState.ResponseDisplay) -> [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .redirects: return !display.data.redirects.isEmpty || display.data.redirectStop != nil
            case .preview: return display.previewKind != nil
            default: return true
            }
        }
    }

    private func responseTabButton(_ tab: Tab, title: String) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            Text(title)
                .fontWeight(isSelected ? .medium : .regular)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 24)
                .background { if isSelected { SelectedChip() } }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func statusBar(_ display: AppState.ResponseDisplay) -> some View {
        let response = display.data
        return HStack(spacing: 16) {
            // Durum kodu rozet (2026-10-20 düzeni): renkli yazı, aynı tonda zemin.
            let statusColor = Theme.statusColor(response.statusCode)
            Text(ResponseExamples.statusLabel(response.statusCode))
                .font(.system(.body, design: .monospaced)).bold()
                .foregroundStyle(statusColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(statusColor.opacity(0.3)))
            if isExample {
                // Örnek bir ölçüm değil: süre saklanmaz, "0 ms" gösterilmez.
                Text(TextStats.size(response.body.count))
                    .foregroundStyle(.secondary)
            } else if let timing = response.timing {
                Button {
                    showingTiming = true
                } label: {
                    Text(String(format: "%.0f ms", response.duration * 1000))
                        .foregroundStyle(.secondary)
                        .iconHitTarget(20)
                }
                .buttonStyle(.plain)
                .help(L10n.t("response.timing.help"))
                .accessibilityLabel(L10n.t("response.timing.accessibility"))
                .popover(isPresented: $showingTiming, arrowEdge: .bottom) {
                    ResponseTimingPopover(timing: timing)
                }
            } else {
                Text(String(format: "%.0f ms", response.duration * 1000))
                    .foregroundStyle(.secondary)
            }
            if isExample {
                EmptyView()
            } else if let size = response.size {
                Button {
                    showingSize = true
                } label: {
                    Text(ResponseSizePopover.bytes(size.responseTotal))
                        .foregroundStyle(.secondary)
                        .iconHitTarget(20)
                }
                .buttonStyle(.plain)
                .help(L10n.t("response.size.help"))
                .accessibilityLabel(L10n.t("response.size.accessibility"))
                .popover(isPresented: $showingSize, arrowEdge: .bottom) {
                    ResponseSizePopover(size: size)
                }
            } else {
                Text(ByteCountFormatter.string(fromByteCount: Int64(response.body.count), countStyle: .binary))
                    .foregroundStyle(.secondary)
            }
            if let correlation = CorrelationID.find(in: response.headers) {
                correlationBadge(correlation)
            }
            if let network = response.network {
                Button {
                    showingNetwork = true
                } label: {
                    Image(systemName: "network")
                        .iconHitTarget(20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L10n.t("response.network.help"))
                .accessibilityLabel(L10n.t("response.network.accessibility"))
                .popover(isPresented: $showingNetwork, arrowEdge: .bottom) {
                    NetworkPopover(info: network)
                }
            }
            if response.bodyLimitExceeded {
                // Tavan (RequestEngine.maxResponseBytes): indirme durduruldu.
                Label(L10n.t("response.truncated", TextStats.size(RequestEngine.maxResponseBytes)), systemImage: "scissors")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.warning)
                    .help(L10n.t("response.truncated.help", TextStats.size(RequestEngine.maxResponseBytes)))
            }
            if response.certificateValidationSkipped {
                Label(L10n.t("response.unverified"), systemImage: "exclamationmark.shield.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
                    .help(L10n.t("response.unverified.help"))
            }
            if !response.redirects.isEmpty {
                Label(L10n.plural("response.redirectCount", count: response.redirects.count), systemImage: "arrow.triangle.turn.up.right.diamond")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.warning)
            }
            if let stop = response.redirectStop {
                Label(stop.explanation, systemImage: "hand.raised.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
            }
            Spacer()
            responseActions(display)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Kopyalama ve kaydetme yalnızca kullanıcı düğmeye bastığında olur;
    /// hiçbir yanıt kendiliğinden panoya ya da diske gitmez.
    private func responseActions(_ display: AppState.ResponseDisplay) -> some View {
        let response = display.data
        let isText = !response.body.isEmpty && response.bodyText != nil
        return HStack(spacing: 10) {
            if !isExample, let id = appState.selectedRequestID {
                saveAsExampleButton(id)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(display.prettyText, forType: .string)
                copied = true
            } label: {
                Label(copied ? L10n.t("common.copied") : L10n.t("common.copy"),
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(!isText)
            .help(isText
                  ? L10n.t("response.copy.help")
                  : L10n.t("response.copy.unavailable"))

            Button {
                saveBodyToFile(response)
            } label: {
                Label(L10n.t("response.saveToFile"), systemImage: "square.and.arrow.down")
            }
            .disabled(response.body.isEmpty)
            .help(response.body.isEmpty
                  ? L10n.t("response.bodyEmpty")
                  : L10n.t("response.saveToFile.help"))
        }
        .buttonStyle(.borderless)
    }

    /// Yanıtı isteğin altına örnek olarak kaydeder. Kesilmiş, çok büyük ya
    /// da Token Factory yanıtında devre dışı; ipucu nedenini söyler.
    private func saveAsExampleButton(_ requestID: UUID) -> some View {
        let reason = appState.exampleUnavailableReason(for: requestID)
        return Button {
            appState.beginSavingExample(for: requestID)
        } label: {
            Label(L10n.t("example.save"), systemImage: "bookmark")
        }
        .disabled(reason != nil || appState.pendingExampleSave != nil)
        .help(reason?.localizedDescription ?? L10n.t("example.save.help"))
    }

    /// Ham byte'lar yazılır (biçimlendirilmiş hali değil): PDF, görsel gibi
    /// ikili yanıtlar bozulmadan kaydedilsin. Konum ve adı kaydetme
    /// penceresinde kullanıcı seçer; Vazgeç derse hiçbir şey yazılmaz.
    private func saveBodyToFile(_ response: ResponseData) {
        let panel = NSSavePanel()
        panel.title = L10n.t("response.saveToFile.panel")
        panel.nameFieldStringValue = ResponseFileName.suggested(for: response)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try response.body.write(to: url, options: .atomic)
        } catch {
            fileSaveError = error.localizedDescription
        }
    }

}
