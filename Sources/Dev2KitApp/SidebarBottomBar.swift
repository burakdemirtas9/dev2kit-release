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
    @State private var showingKibanaImport = false
    @State private var showingOpenAPIImport = false
    @State private var showingSourceImport = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button {
                    appState.addCollection()
                } label: {
                    Label("Yeni Koleksiyon", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                Menu {
                    Button("dev2kit Koleksiyonu…") {
                        pendingImportSource = .dev2kit
                        showingImporter = true
                    }
                    Divider()
                    Button("Postman'den Otomatik Al…") {
                        showingPostmanImport = true
                    }
                    Button("Postman Dosyası…") {
                        pendingImportSource = .postman
                        showingImporter = true
                    }
                    Divider()
                    Button("cURL'den İstek…") {
                        showingCurlImport = true
                    }
                    Button("Kibana Logundan İstek…") {
                        showingKibanaImport = true
                    }
                    Divider()
                    Button("Swagger / OpenAPI Adresinden…") {
                        showingOpenAPIImport = true
                    }
                    Button("Kaynak Koddan Giden İstekler…") {
                        showingSourceImport = true
                    }
                } label: {
                    Label("İçe Aktar", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Koleksiyon ya da istek içe aktar (dev2kit, Postman, cURL, Kibana, OpenAPI)")
            }
            .padding(8)
        }
        .background(.bar)
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
        .sheet(isPresented: $showingKibanaImport) {
            KibanaImportView()
        }
        .sheet(isPresented: $showingOpenAPIImport) {
            OpenAPIImportView()
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
}
