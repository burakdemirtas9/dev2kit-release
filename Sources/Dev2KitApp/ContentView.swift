import SwiftUI
import Dev2KitCore

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var showingSecrets = false
    @State private var showingEnvironments = false
    @State private var showingCookies = false
    @State private var showingHistory = false
    @State private var showingTLS = false

    private static let sidebarWidthKey = "sidebarWidth"
    private static let minSidebarWidth: CGFloat = 220
    private static let splitSpace = "splitContainer"

    /// İlk açılışta minimum; sonraki açılışlarda kullanıcının bıraktığı genişlik.
    @State private var sidebarWidth: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: ContentView.sidebarWidthKey)
        return stored >= ContentView.minSidebarWidth ? CGFloat(stored) : ContentView.minSidebarWidth
    }()
    @State private var isHoveringDivider = false

    /// Genişlik sınırları: alt 220, üst içerik genişliği — ve detay paneline
    /// en az 480px kalacak şekilde pencereye göre kırpılır.
    private func effectiveSidebarWidth(totalWidth: CGFloat) -> CGFloat {
        let upper = max(Self.minSidebarWidth, min(appState.sidebarMaxWidth, totalWidth - 489))
        return min(max(sidebarWidth, Self.minSidebarWidth), upper)
    }

    /// macOS 26 yan yana duran araç çubuğu düğmelerini tek bir cam kapsülde
    /// grupluyor; tema seçicisi Picker olunca Environment'lar ve Geçmiş ile
    /// birleşiyordu. Sabit ayırıcı her birini kendi düğmesi olarak tutar.
    /// Eski sürümlerde gruplama yok, ayırıcı da yok.
    @ToolbarContentBuilder
    private var toolbarGroupBreak: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }
    }

    /// API Client modu: kenar çubuğu, sekmeler, istek editörü.
    private var apiClientLayout: some View {
        // Genişlik tamamen bizde: HSplitView/NavigationSplitView ayraç konumunu
        // dışarıdan vermeye izin vermiyor (ilk açılış + kalıcılık için gerekli).
        GeometryReader { geometry in
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: effectiveSidebarWidth(totalWidth: geometry.size.width))
                sidebarDivider(totalWidth: geometry.size.width)
                VStack(spacing: 0) {
                    if !appState.openTabs.isEmpty {
                        RequestTabBar()
                        Divider()
                    }
                    if let requestBinding = appState.selectedRequest {
                        RequestDetailView(request: requestBinding)
                    } else {
                        NoRequestSelectedView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .coordinateSpace(name: Self.splitSpace)
            // Sürüklerken örtük animasyon genişliği "kovalayınca" titreme oluyor.
            .animation(nil, value: sidebarWidth)
        }
    }

    /// Pencerenin üst ortasındaki mod seçici: sistemin segmentli kontrolü
    /// (cam başparmak, sürüklenebilir) + seçili modda yeşil nokta
    /// (`ModeSegmentedControl`, TASARIM §1 istisnası).
    private var modePicker: some View {
        @Bindable var state = appState
        return ModeSegmentedControl(selection: $state.mode)
            .fixedSize()
            .help("API Client ile Workbench arasında geç")
    }

    var body: some View {
        @Bindable var state = appState
        Group {
            // Mod değişince API Client görünümü kurulmaz ama durumu AppState'te
            // (sekmeler, gövde, yanıtlar) kaldığı için geri dönünce yerindedir.
            if appState.isAPIClient {
                apiClientLayout
            } else {
                WorkbenchView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                modePicker
            }
            // Environment, geçmiş, çerez, TLS ve secret yalnızca API Client'ta
            // anlamlı; Workbench'te gizlenir (docs/V2.md).
            if appState.isAPIClient {
                ToolbarItem(placement: .automatic) {
                    EnvironmentPicker()
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingEnvironments = true
                    } label: {
                        Label("Environment'lar", systemImage: "globe")
                    }
                    .help("Environment oluştur ve düzenle")
                }
                toolbarGroupBreak
            }
            ToolbarItem(placement: .automatic) {
                // Picker olarak kurulur: araç çubuğu "simge ve metin" modunda
                // Menu'nun başlığını göstermiyordu (Label da, Menu(_:systemImage:)
                // de denendi); Picker'ın başlığı etiket olarak çıkıyor.
                Picker(selection: $state.appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Label(mode.label, systemImage: mode.icon).tag(mode)
                    }
                } label: {
                    Label("Görünüm", systemImage: appState.appearanceMode.icon)
                }
                .pickerStyle(.menu)
                // Diğer araç çubuğu düğmeleri gibi dar kalsın: seçenekler
                // zaten tıklayınca açılan listede.
                .menuIndicator(.hidden)
                .frame(width: 36)
                .help("Açık/koyu görünüm")
            }
            if appState.isAPIClient {
                toolbarGroupBreak
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingHistory = true
                    } label: {
                        Label("Geçmiş", systemImage: "clock.arrow.circlepath")
                    }
                    .help("Gönderilen isteklerin kaydı (⌘Y)")
                    .keyboardShortcut("y", modifiers: .command)
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingCookies = true
                    } label: {
                        Label {
                            Text("Çerezler")
                        } icon: {
                            CookieIcon().frame(width: 15, height: 15)
                        }
                    }
                    .help("Oturum çerezlerini görüntüle ve temizle")
                }
            }
            // Güvenlik durumu her modda görünür (docs/TASARIM.md §1): Workbench'e
            // geçince açık kalan doğrulama gizlenmesin.
            // Doğrulama kapalıyken her an görünür olmalı: açık unutulursa
            // kullanıcı bunu bir yanıta bakana kadar fark etmezdi.
            // Tıklamak durumu DEĞİŞTİRMEZ, TLS ayarlarını açar; açıp kapatmak
            // oradaki anahtardan (kullanıcı isteği, 2026-10-20: tek tıkla
            // sessizce açılması beklenmedik bir durum değişikliğiydi).
            if appState.certificateValidationDisabled {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingTLS = true
                    } label: {
                        // Arıza değil, açık bir risk: uyarı üçgeni. Renk bilerek
                        // kırmızı (güvenlik gevşemesi her an göze çarpmalı).
                        Label("Doğrulama kapalı", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .foregroundStyle(Theme.down)
                    .help("TLS ayarlarını aç")
                }
            }
            if appState.isAPIClient {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingTLS = true
                    } label: {
                        Label("TLS", systemImage: "lock.shield")
                    }
                    .help("Kurum CA'sı ve istemci sertifikası profilleri")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingSecrets = true
                    } label: {
                        Label("Secrets", systemImage: "key.fill")
                    }
                    .help("Keychain'deki secret'ları yönet")
                }
            }
        }
        .sheet(isPresented: $showingSecrets) {
            SecretsView()
        }
        .sheet(isPresented: $showingEnvironments) {
            EnvironmentsView()
        }
        .sheet(isPresented: $showingCookies) {
            CookiesView()
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView()
        }
        .sheet(isPresented: $showingTLS) {
            TLSSettingsView()
        }
        // Yanıt panelindeki TLS öneri kutusundaki "Profili Aç" buraya bağlanır
        // (açılınca o profil seçili gelir).
        // Alandaki tanımsız {{değişken}}e tıklama: Environment'lar penceresi
        // değişkenin değer alanında açılır.
        .onChange(of: appState.environmentsRequest) {
            showingEnvironments = true
        }
        .onChange(of: appState.tlsSettingsRequest) {
            showingTLS = true
        }
        // Mesajlar tek kuyruktan (`presentedMessage`; açılış önce, kayıt
        // hatası gelse de kaybolmasın). Gerçek hata sistem alert'inde;
        // bilgi, başarı ve uyarı türüne göre ikonlu sonuç penceresinde
        // (sistem alert'i tür gösteremiyor). docs/TASARIM.md "Mesaj tipleri".
        .alert(
            state.presentedMessage?.title ?? "",
            isPresented: .constant(state.presentedMessage?.kind == .error)
        ) {
            if let url = state.presentedMessage?.revealURL {
                Button("Finder'da Göster") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    state.dismissPresentedMessage()
                }
            }
            Button("Tamam") { state.dismissPresentedMessage() }
        } message: {
            if let message = state.presentedMessage {
                Text(([message.message].compactMap { $0 } + message.lines.map(\.text)).joined(separator: "\n"))
            }
        }
        .sheet(item: Binding(
            get: { state.presentedMessage.flatMap { $0.kind == .error ? nil : $0 } },
            // Kapatma yalnızca pencerenin kendi düğmesinden (id ile): buradan
            // kapatmak sıradaki mesajı da silebilirdi.
            set: { _ in }
        )) { message in
            ResultSheet(message: message) { state.dismissMessage(message.id) }
        }
    }

    /// Sürüklenebilir dikey ayraç: 1px çizgi + 9px görünmez tutma alanı.
    /// Bırakınca genişlik UserDefaults'a yazılır, sonraki açılışta geri gelir.
    private func sidebarDivider(totalWidth: CGFloat) -> some View {
        ZStack {
            Color.clear
                .frame(width: 9)
                .contentShape(Rectangle())
            // Görünür çizgi yok: kenar çubuğu camlı zeminiyle ayrışıyor
            // (Workbench'teki gibi, 2026-10-20). Sürükleme alanı duruyor.
        }
        // push/pop dengesiz kalırsa imleç yığını bozuluyor (ayraç üstündeyken
        // pencere değişince "pop" gelmeyebiliyor); bayrakla eşleştiriliyor.
        .onHover { hovering in
            guard hovering != isHoveringDivider else { return }
            isHoveringDivider = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
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
        // translation yerine konteynerdeki mutlak konum kullanılıyor: ayraç
        // sürüklendikçe kendi koordinat uzayı da kaydığı için translation
        // geri besleme yapıp titremeye yol açıyordu.
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.splitSpace))
                .onChanged { value in
                    let upper = max(Self.minSidebarWidth, min(appState.sidebarMaxWidth, totalWidth - 489))
                    sidebarWidth = min(max(value.location.x, Self.minSidebarWidth), upper)
                }
                .onEnded { _ in
                    UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey)
                }
        )
    }
}
