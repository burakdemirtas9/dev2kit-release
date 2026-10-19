import AppKit
import SwiftUI
import Dev2KitCore

struct ResponseView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: Tab = .body
    @State private var copied = false
    @State private var fileSaveError: String?
    @State private var showingNetwork = false
    @State private var showingTiming = false
    @State private var showingSize = false
    @State private var copiedCorrelationID = false
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
    }

    var body: some View {
        switch appState.lastResponse {
        case .idle:
            ContentUnavailableView(
                "Henüz yanıt yok",
                systemImage: "arrow.down.circle",
                description: Text("⌘⏎ ile isteği gönder.")
            )
        case .loading:
            ProgressView("Gönderiliyor…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failure(let message):
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "İstek başarısız",
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
                title: "İstek engellendi",
                subtitle: "Bu istek gönderilmedi ve bu haliyle gönderilemez.",
                icon: "xmark.shield.fill",
                tint: Theme.down
            )
        case .needsApproval(let findings):
            securityReview(
                findings,
                title: "İstek durduruldu",
                subtitle: "Gönderilmeden önce kontrol etmen gereken durumlar var. Onaylarsan aynı durum bir daha sorulmaz.",
                icon: "exclamationmark.shield.fill",
                tint: Theme.warning
            ) {
                HStack {
                    Spacer()
                    Button("Vazgeç", role: .cancel) {
                        appState.dismissSecurityReview()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Yine de Gönder") {
                        appState.approveAndSend(findings)
                    }
                }
            }
        case .success(let display):
            let response = display.data
            VStack(spacing: 0) {
                statusBar(display)
                if let id = appState.selectedRequestID, let advice = appState.tokenRetryAdvice[id] {
                    TokenRetryBanner(requestID: id, advice: advice)
                }
                // Sekmeler istek sekmeleriyle aynı dilde: sola yaslı, seçili
                // olan camlı (2026-10-20). Arama ve katlama sağda, yalnızca
                // gövde sekmesinde.
                HStack(spacing: 2) {
                    ForEach(availableTabs(display), id: \.self) { tab in
                        responseTabButton(tab, title: tab == .redirects ? "\(tab.rawValue) (\(response.redirects.count))" : tab.rawValue)
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
                    if !display.fitsEditor {
                        OversizedTextNotice(
                            title: "Yanıt gövdesi gösterilmiyor: \(TextStats.size(display.prettyText.utf8.count))",
                            detail: "\(TextStats.size(WorkbenchLimits.maxOutputBytes))'tan büyük ya da \(TextStats.size(WorkbenchLimits.maxEditorLineBytes))'tan uzun satırlı metin (biçimlenemeyen sıkıştırılmış veri tek satırdır) editörde dev2kit'i dondurur. Gövde bellekte; kopyalayabilirsin."
                        ) {
                            CopyButton(text: display.prettyText, help: "Yanıt gövdesini kopyala")
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
                                Text("Satır \(cursor.line), Sütun \(cursor.column)")
                            }
                        } trailing: {
                            Text(display.stats.summaryTR)
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
                    List(Array(response.headers.enumerated()), id: \.offset) { _, header in
                        HStack(alignment: .top) {
                            Text(header.name)
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.semibold)
                                .frame(width: 220, alignment: .leading)
                            Text(header.value)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
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
            .task(id: copiedCorrelationID) {
                guard copiedCorrelationID else { return }
                try? await Task.sleep(for: .seconds(1.5))
                copiedCorrelationID = false
            }
            .alert(
                "Dosyaya kaydedilemedi",
                isPresented: Binding(
                    get: { fileSaveError != nil },
                    set: { if !$0 { fileSaveError = nil } }
                )
            ) {
                Button("Tamam") { fileSaveError = nil }
            } message: {
                Text(fileSaveError ?? "")
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
                            "Farklı host: \(step.strippedHeaders.joined(separator: ", ")) başlıkları düşürüldü",
                            systemImage: "lock.shield.fill"
                        )
                        .font(.secondaryText)
                        .foregroundStyle(Theme.up)
                    }
                }
                .padding(.vertical, 2)
            }
            if let stop = response.redirectStop {
                Label("Zincir kesildi: \(stop.explanation)", systemImage: "hand.raised.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
            }
            if let final = response.finalURL {
                Label("Son adres: \(final.absoluteString)", systemImage: "flag.checkered")
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .listStyle(.inset)
    }

    /// İzleme kimliği rozeti. Tıklayınca panoya kopyalar — log sistemine
    /// (Kibana) bu kimlikle gidiliyor, elle seçip kopyalamak zahmetli.
    /// Pano kuralı bozulmuyor: kopyalama yalnızca kullanıcı tıklayınca olur.
    private func correlationBadge(_ correlation: CorrelationID.Match) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(correlation.value, forType: .string)
            copiedCorrelationID = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copiedCorrelationID ? "checkmark" : "number")
                Text(copiedCorrelationID ? "Kopyalandı" : CorrelationID.shortened(correlation.value))
                    .font(.secondaryMono)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("\(correlation.explanation)\n\n\(correlation.headerName): \(correlation.value)\n\nTıkla, panoya kopyalansın.")
        .accessibilityLabel("İzleme kimliğini kopyala")
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
            let statusColor = response.isSuccess ? Theme.up : (response.statusCode < 500 ? Theme.warning : Theme.down)
            Text("\(response.statusCode)")
                .font(.system(.body, design: .monospaced)).bold()
                .foregroundStyle(statusColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(statusColor.opacity(0.3)))
            if let timing = response.timing {
                Button {
                    showingTiming = true
                } label: {
                    Text(String(format: "%.0f ms", response.duration * 1000))
                        .foregroundStyle(.secondary)
                        .iconHitTarget(20)
                }
                .buttonStyle(.plain)
                .help("Sürenin aşamalara dağılımı: DNS, TCP, TLS, bekleme, indirme")
                .accessibilityLabel("Yanıt süresi kırılımı")
                .popover(isPresented: $showingTiming, arrowEdge: .bottom) {
                    ResponseTimingPopover(timing: timing)
                }
            } else {
                Text(String(format: "%.0f ms", response.duration * 1000))
                    .foregroundStyle(.secondary)
            }
            if let size = response.size {
                Button {
                    showingSize = true
                } label: {
                    Text(ResponseSizePopover.bytes(size.responseTotal))
                        .foregroundStyle(.secondary)
                        .iconHitTarget(20)
                }
                .buttonStyle(.plain)
                .help("İstek ve yanıt boyutu: başlıklar ve gövde ayrı")
                .accessibilityLabel("Boyut ayrıntısı")
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
                .help("Bağlantı künyesi: protokol, adresler, TLS ve sertifika")
                .accessibilityLabel("Bağlantı künyesi")
                .popover(isPresented: $showingNetwork, arrowEdge: .bottom) {
                    NetworkPopover(info: network)
                }
            }
            if response.bodyLimitExceeded {
                // Tavan (RequestEngine.maxResponseBytes): indirme durduruldu.
                Label("Yanıt \(TextStats.size(RequestEngine.maxResponseBytes))'ı aştı, kesildi", systemImage: "scissors")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.warning)
                    .help("Yanıt \(TextStats.size(RequestEngine.maxResponseBytes))'tan büyük; bellek dolmasın diye indirme durduruldu. Yalnızca ilk \(TextStats.size(RequestEngine.maxResponseBytes)) gösteriliyor, kopyalanan ve kaydedilen de bu kadar.")
            }
            if response.certificateValidationSkipped {
                Label("Sertifika doğrulanmadı", systemImage: "exclamationmark.shield.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
                    .help("Bu yanıt, sunucu sertifikası doğrulanmadan kurulan bir bağlantıdan geldi. Kaynağın gerçekten o sunucu olduğu garanti değil.")
            }
            if !response.redirects.isEmpty {
                Label("\(response.redirects.count) yönlendirme", systemImage: "arrow.triangle.turn.up.right.diamond")
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
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(display.prettyText, forType: .string)
                copied = true
            } label: {
                Label(copied ? "Kopyalandı" : "Kopyala",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(!isText)
            .help(isText
                  ? "Görünen gövdeyi panoya kopyalar"
                  : "Gövde boş ya da metin değil; Dosyaya Kaydet ile alabilirsin")

            Button {
                saveBodyToFile(response)
            } label: {
                Label("Dosyaya Kaydet…", systemImage: "square.and.arrow.down")
            }
            .disabled(response.body.isEmpty)
            .help(response.body.isEmpty
                  ? "Gövde boş"
                  : "Sunucudan gelen ham gövdeyi, seçtiğin konuma kaydeder")
        }
        .buttonStyle(.borderless)
    }

    /// Ham byte'lar yazılır (biçimlendirilmiş hali değil): PDF, görsel gibi
    /// ikili yanıtlar bozulmadan kaydedilsin. Konum ve adı kaydetme
    /// penceresinde kullanıcı seçer; Vazgeç derse hiçbir şey yazılmaz.
    private func saveBodyToFile(_ response: ResponseData) {
        let panel = NSSavePanel()
        panel.title = "Yanıtı Dosyaya Kaydet"
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
