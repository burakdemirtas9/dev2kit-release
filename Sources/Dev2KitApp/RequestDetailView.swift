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
                // Genişlik SINIRLI: `fixedSize` ile ad kadar yer isteyince
                // `windowResizability(.contentMinSize)` bunu pencerenin asgari
                // ölçüsü sayıp uzun adlı istek seçildiğinde pencereyi büyütüyor
                // ve kaydırıyordu (900 -> 1288 punto ölçüldü). Sekme değişimi
                // bu yüzden de sıçramalı görünüyordu.
                TextField("İstek adı", text: $request.name)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: 360, alignment: .leading)

                if appState.isDirty(request.id) {
                    Button {
                        showingRevertConfirm = true
                    } label: {
                        Label("son gönderilenden farklı", systemImage: "circle.fill")
                            .font(.caption)
                            .labelStyle(DirtyLabelStyle())
                            .frame(minHeight: 20)
                            .contentShape(Rectangle())
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
