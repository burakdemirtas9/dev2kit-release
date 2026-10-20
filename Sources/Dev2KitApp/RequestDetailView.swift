import AppKit
import SwiftUI
import Dev2KitCore

struct RequestDetailView: View {
    @Environment(AppState.self) private var appState
    @Binding var request: RequestModel
    @State private var showingCurl = false
    @State private var showingOptions = false
    @State private var showingRevertConfirm = false
    /// Adres ↔ Params eşitlemesi (QueryParamSync): yazma durunca. Yazmaya
    /// başlamadan önceki hal, eski kayıtların parametreleri kaybolmasın diye.
    @State private var syncTask: Task<Void, Never>?
    @State private var urlBeforeEdit: String?
    @State private var paramsBeforeEdit: [KeyValueEntry]?

    private static let responseHeightKey = "responseHeight"
    private static let minTopHeight: CGFloat = 220
    private static let minResponseHeight: CGFloat = 160
    private static let splitSpace = "requestDetailSplit"

    /// Yanıt panelinin yüksekliği. İlk açılışta yarı yarıya, sonrasında
    /// kullanıcının bıraktığı yer.
    @State private var responseHeight: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: RequestDetailView.responseHeightKey)
        return stored >= RequestDetailView.minResponseHeight ? CGFloat(stored) : 0
    }()
    @State private var isHoveringDivider = false

    /// Pencereye sığdırılmış yanıt yüksekliği.
    private func effectiveResponseHeight(total: CGFloat) -> CGFloat {
        let upper = max(Self.minResponseHeight, total - Self.minTopHeight - Self.dividerThickness)
        let wanted = responseHeight > 0 ? responseHeight : total * 0.45
        return min(max(wanted, Self.minResponseHeight), upper)
    }

    private static let dividerThickness: CGFloat = 9

    /// Dikey bölme ELDE yapılıyor, `VSplitView` ile değil.
    ///
    /// `VSplitView` (NSSplitView) yanıt paneli küçüldüğünde boşalan yeri üst
    /// panele vermiyor, iki paneli birden aşağı itip TEPEDE boşluk bırakıyordu:
    /// sekme çubuğuyla istek adı arasında bir şerit. Ölçüldü:
    /// yanıt 273 -> 160 punto küçülünce üst panel y=85'ten y=198'e kaydı,
    /// aradaki 113 punto tam olarak küçülme miktarıydı. Aralıklı olmasının
    /// sebebi de bu: ancak yanıt paneli asgarisine inince ortaya çıkıyor.
    /// `maxHeight: .infinity` eklemek çözmedi (y=146 ve y=296'ya kaydığı
    /// yeniden ölçüldü). Sidebar ayracı da aynı gerekçeyle elde yapılmıştı.
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    if isTokenFactory {
                        TokenFactoryBanner(variable: (request.tokenOutput ?? TokenOutput()).trimmedVariableName)
                    }
                    requestBar
                    editorTabs
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()

                splitter(total: geometry.size.height)

                ResponseView()
                    .frame(height: effectiveResponseHeight(total: geometry.size.height))
                    .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: Self.splitSpace)
            // Sürüklerken örtük animasyon yüksekliği "kovalayınca" titriyor.
            .animation(nil, value: responseHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let alert = appState.tokenAlert, alert.requestID == request.id {
                TokenAlertToast(alert: alert)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: appState.tokenAlert)
    }

    private var isTokenFactory: Bool { appState.isTokenFactoryRequest(request.id) }

    private func splitter(total: CGFloat) -> some View {
        ZStack {
            Color.clear
                .frame(height: Self.dividerThickness)
                .contentShape(Rectangle())
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
        // push/pop dengesiz kalırsa imleç yığını bozuluyor; bayrakla eşleşiyor.
        .onHover { hovering in
            guard hovering != isHoveringDivider else { return }
            isHoveringDivider = hovering
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHoveringDivider {
                isHoveringDivider = false
                NSCursor.pop()
            }
        }
        // Konteynerdeki mutlak konum kullanılıyor: translation, ayraç
        // sürüklendikçe kendi koordinat uzayı kaydığı için geri besleme
        // yapıp titremeye yol açıyor (sidebar ayracında da böyle).
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.splitSpace))
                .onChanged { value in
                    let upper = max(Self.minResponseHeight, total - Self.minTopHeight - Self.dividerThickness)
                    responseHeight = min(max(total - value.location.y, Self.minResponseHeight), upper)
                }
                .onEnded { _ in
                    UserDefaults.standard.set(Double(responseHeight), forKey: Self.responseHeightKey)
                }
        )
    }

    /// Ad satırı ve denetim satırı alt alta.
    ///
    /// Ad satırı eskiden `requestBar`'ın üstüne `safeAreaInset(edge: .top)` ile
    /// konuyordu. Sadeleştirildi: ad satırı bir güvenli alan değil, sıradan bir
    /// başlık. (Yerleşim boşluğu hatasının sebebi bu DEĞİLDİ; o `VSplitView`'dan
    /// geliyordu — yukarıdaki nota bak.)
    private var requestBar: some View {
        VStack(spacing: 0) {
            titleRow
            controlsRow
        }
        .confirmationDialog(
            "Son gönderilen hale dönülsün mü?",
            isPresented: $showingRevertConfirm,
            titleVisibility: .visible
        ) {
            Button("Düzenlemeleri Sil", role: .destructive) {
                appState.revertToLastSent(request.id)
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Son gönderimden sonraki düzenlemelerin silinir. Geri alınamaz.")
        }
    }

    private var controlsRow: some View {
        HStack(alignment: .top, spacing: 8) {
            // Metot + adres tek kapsülde (API Client yeni düzen, 2026-10-20).
            TemplateTextField(
                placeholder: "https://api.example.com/{{path}}",
                text: urlBinding,
                limit: .url,
                onSubmit: { appState.send(request) },
                capsuleLeading: AnyView(
                    MethodPicker(selection: $request.method, bordered: false)
                        .frame(width: 92)
                        .padding(.leading, 4)
                )
            )

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
                        .padding(.horizontal, 6)
                        .frame(height: 28)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(request.url.isEmpty)
            }

            Button {
                showingOptions = true
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 16, height: 22)
            }
            .help("İstek ayarları: zaman aşımı, yönlendirme, çerez")
            .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
                RequestOptionsPopover(options: $request.options)
            }

            Button {
                showingCurl = true
            } label: {
                Image(systemName: "terminal")
                    .frame(width: 16, height: 22)
            }
            .help("cURL komutu olarak al")
            .disabled(request.url.isEmpty)
            .popover(isPresented: $showingCurl, arrowEdge: .bottom) {
                CurlPopover(request: request)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// İstek adı ve kayıt durumu.
    private var titleRow: some View {
        HStack(spacing: 8) {
            // Genişlik SINIRLI: `fixedSize` ile ad kadar yer isteyince
            // `windowResizability(.contentMinSize)` bunu pencerenin asgari
            // ölçüsü sayıp uzun adlı istek seçildiğinde pencereyi büyütüyor
            // ve kaydırıyordu (900 -> 1288 punto ölçüldü). Sekme değişimi
            // bu yüzden de sıçramalı görünüyordu.
            TextField("İstek adı", text: $request.name)
                .inputLimit(.name)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 360, alignment: .leading)

            if appState.isDirty(request.id) {
                Button {
                    showingRevertConfirm = true
                } label: {
                    Label("son gönderilenden farklı", systemImage: "circle.fill")
                        .font(.secondaryText)
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
        .frame(height: 34)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Otomatik kaydın görünür hali.
    @ViewBuilder
    private var saveStatus: some View {
        switch appState.saveState {
        case .idle:
            EmptyView()
        case .pending:
            Label("Kaydediliyor…", systemImage: "arrow.triangle.2.circlepath")
                .font(.tinyText)
                .foregroundStyle(.tertiary)
        case .saved(let date):
            Label("Kaydedildi \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                .font(.tinyText)
                .foregroundStyle(.tertiary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.tinyText)
                .foregroundStyle(Theme.down)
                .lineLimit(1)
        }
    }

    private var editorTabs: some View {
        @Bindable var state = appState
        // Açık sekme AppState'te: ⌘1…⌘4 menü komutları view @State'ine erişemez.
        return VStack(spacing: 0) {
            // Sarı nokta: içeriği olan sekme (şimdilik gövde; kural Core'da,
            // `RequestBody.hasContent`). Sistem segmentli kontrolü renkli noktayı
            // çizmediği için kendi seçicimiz (bkz. EditorTabPicker).
            EditorTabPicker(
                selection: $state.editorTab,
                tabs: EditorTab.available(isTokenFactory: isTokenFactory),
                marked: request.body.hasContent ? [.body] : [],
                counts: [.headers: request.activeHeaderCount, .params: request.activeQueryParamCount]
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()

            // Token sekmesi açıkken normal bir isteğe geçilirse Headers'a düşülür.
            switch appState.editorTab == .token && !isTokenFactory ? .headers : appState.editorTab {
            case .headers:
                KeyValueEditor(
                    entries: $request.headers,
                    keyPlaceholder: "Header-Adi",
                    valuePlaceholder: "değer veya {{secret:isim}}",
                    keyNote: { key in
                        Dev2KitIdentity.isUserAgent(key)
                            ? "Yok sayılır: dev2kit her istekte kendi User-Agent'ını (\(Dev2KitIdentity.userAgent)) gönderir, değiştirilemez. Sunucu loglarında test trafiği ayırt edilsin diye."
                            : nil
                    }
                )
            case .body:
                BodyEditor(body: $request.body)
            case .auth:
                AuthEditor(auth: $request.auth)
            case .params:
                KeyValueEditor(entries: paramsBinding, keyPlaceholder: "param", valuePlaceholder: "değer veya {{degisken}}")
            case .token:
                TokenOutputEditor(request: $request)
            }
        }
    }

    // MARK: Adres ↔ Params eşitlemesi

    /// Yazma durduktan sonra eşitlenir (kullanıcı isteği: "type bitince").
    static let querySyncDelay: Duration = .milliseconds(500)

    /// Adres alanı: yalnızca KULLANICININ yazması eşitlemeyi tetikler. İstek
    /// değiştirmek tetiklemez (eski kayıtta parametreleri silerdi).
    private var urlBinding: Binding<String> {
        Binding(
            get: { request.url },
            set: { newValue in
                // Odak değişirken SwiftUI aynı değeri yeniden yazıyor: düzenleme
                // değil, bekleyen eşitlemeyi bozmasın (testle bulundu).
                guard newValue != request.url else { return }
                if urlBeforeEdit == nil { urlBeforeEdit = request.url }
                paramsBeforeEdit = nil
                request.url = newValue
                scheduleQuerySync {
                    guard let before = urlBeforeEdit else { return }
                    urlBeforeEdit = nil
                    apply(QueryParamSync.afterURLEdit(urlBefore: before, url: request.url, params: request.queryParams))
                }
            }
        )
    }

    /// Params tablosu (satırlar ve toplu düzenleme).
    private var paramsBinding: Binding<[KeyValueEntry]> {
        Binding(
            get: { request.queryParams },
            set: { newValue in
                guard newValue != request.queryParams else { return }
                if paramsBeforeEdit == nil { paramsBeforeEdit = request.queryParams }
                urlBeforeEdit = nil
                request.queryParams = newValue
                scheduleQuerySync {
                    guard let before = paramsBeforeEdit else { return }
                    paramsBeforeEdit = nil
                    apply(QueryParamSync.afterParamsEdit(url: request.url, paramsBefore: before, params: request.queryParams))
                }
            }
        )
    }

    private func scheduleQuerySync(_ work: @escaping @MainActor () -> Void) {
        syncTask?.cancel()
        let requestID = request.id
        syncTask = Task { @MainActor in
            try? await Task.sleep(for: Self.querySyncDelay)
            // İptal = yeni bir tuş geldi: başlangıç hali yeni görevde lazım,
            // SİLİNMEZ (silinince eşitleme hiç yapılmıyordu; testle bulundu).
            guard !Task.isCancelled else { return }
            // Bu arada başka isteğe geçildiyse eşitleme yapılmaz.
            guard request.id == requestID else {
                urlBeforeEdit = nil
                paramsBeforeEdit = nil
                return
            }
            work()
        }
    }

    /// Yalnızca değişen taraf yazılır (gereksiz "kaydedilmedi" işareti olmasın).
    private func apply(_ synced: QueryParamSync.Synced) {
        if synced.params != request.queryParams { request.queryParams = synced.params }
        if synced.url != request.url { request.url = synced.url }
    }
}
