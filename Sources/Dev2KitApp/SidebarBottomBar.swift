import SwiftUI
import Dev2KitCore

/// Kenar çubuğunun alt çubuğu: yeni koleksiyon ve içe aktarma menüsü.
///
/// İçe aktarma ekranları (dosya seçici, Postman, cURL, Kibana, OpenAPI,
/// kaynak tarama, inceleme) burada: onları açan menüyle aynı yerde dururlar,
/// liste görünümü yalnızca listeyi bilir.
struct SidebarBottomBar: View {
    @Environment(AppState.self) private var appState
    @State private var showingImporter = false
    @State private var pendingImportSource: AppState.ImportSource = .dev2kit
    @State private var showingPostmanImport = false
    @State private var showingCurlImport = false
    @State private var showingSourceImport = false
    @State private var showingAutoImport = false
    /// Kibana ve OpenAPI ekranları `sheet(item:)` ile: otomatik içe
    /// aktarmanın verdiği JSON sayfayı açan değerin İÇİNDE. Önce ayrı bir
    /// durum değişkeni yazıp `isPresented` ile açınca SwiftUI sayfayı eski
    /// (boş) değerle kuruyordu; kullanıcı JSON'u yeniden yapıştırmak zorunda
    /// kaldı (2026-10-19).
    @State private var kibanaSheet: ImportPrefill?
    @State private var openAPISheet: ImportPrefill?

    struct ImportPrefill: Identifiable {
        let id = UUID()
        let json: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button {
                    appState.addCollection()
                } label: {
                    // Varsayılan kenar çubuğu genişliğinde iki dilde de sığsın:
                    // Türkçede kısa etiket ("İçe Aktar" daha geniş, "Yeni
                    // Koleksiyon" kırpılıyordu); tam metin ipucunda.
                    Label(L10n.t("sidebar.newCollection.short"), systemImage: "folder.badge.plus")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .help(L10n.t("menu.newCollection"))
                Menu {
                    Button(L10n.t("import.menu.auto")) {
                        showingAutoImport = true
                    }
                    Divider()
                    Button(L10n.t("import.menu.dev2kit")) {
                        pendingImportSource = .dev2kit
                        showingImporter = true
                    }
                    Divider()
                    Button(L10n.t("import.menu.postmanAccount")) {
                        showingPostmanImport = true
                    }
                    Button(L10n.t("import.menu.postmanFile")) {
                        pendingImportSource = .postman
                        showingImporter = true
                    }
                    Divider()
                    Button(L10n.t("import.menu.curl")) {
                        showingCurlImport = true
                    }
                    Button(L10n.t("import.menu.kibana")) {
                        kibanaSheet = ImportPrefill(json: nil)
                    }
                    Divider()
                    Button(L10n.t("import.menu.openapi")) {
                        openAPISheet = ImportPrefill(json: nil)
                    }
                    Button(L10n.t("import.menu.source")) {
                        showingSourceImport = true
                    }
                } label: {
                    Label(L10n.t("import.menu.title"), systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L10n.t("import.menu.help"))
            }
            .padding(8)
        }
        // Zemin kenar çubuğu malzemesi (SidebarView).
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json]
        ) { result in
            if case .success(let url) = result {
                appState.importCollection(from: url, source: pendingImportSource)
            }
        }
        .sheet(isPresented: $showingPostmanImport) {
            PostmanImportView()
        }
        .sheet(isPresented: $showingCurlImport) {
            CurlImportView()
        }
        .sheet(item: $kibanaSheet) { prefill in
            KibanaImportView(initialJSON: prefill.json)
        }
        .sheet(item: $openAPISheet) { prefill in
            OpenAPIImportView(initialJSON: prefill.json)
        }
        .sheet(isPresented: $showingAutoImport) {
            // Sonraki ekran (inceleme, OpenAPI, Kibana) bu sayfa kapandıktan
            // SONRA açılır: aynı anda iki sayfa açmaya çalışmak birini yutuyor.
            AutoImportView(
                onPrepared: { prepared in afterSheetCloses { appState.importPrepared(prepared) } },
                onOpenOpenAPI: { json in afterSheetCloses { openAPISheet = ImportPrefill(json: json) } },
                onOpenKibana: { json in afterSheetCloses { kibanaSheet = ImportPrefill(json: json) } }
            )
        }
        .sheet(isPresented: $showingSourceImport) {
            SourceImportView()
        }
        .sheet(item: Binding(
            get: { appState.pendingImport },
            set: { appState.pendingImport = $0 }
        )) { pending in
            ImportReviewView(
                items: pending.items,
                onConfirm: {
                    appState.pendingImport = nil
                    appState.portingMessage = appState.commitImport(pending.items)
                },
                onCancel: { appState.pendingImport = nil }
            )
        }
    }

    /// Sayfa kapanma animasyonu bitince: SwiftUI aynı anda kapanan ve açılan
    /// iki sayfadan ikincisini gösteremiyor.
    private func afterSheetCloses(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action)
    }
}
