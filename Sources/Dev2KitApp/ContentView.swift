import SwiftUI
import Dev2KitCore

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var showingSecrets = false
    @State private var showingEnvironments = false
    @State private var showingCookies = false
    @State private var showingHistory = false
    @State private var showingTLS = false
    /// Mod bir kez kurulduysa gizlense de canlı tutulur (bkz. body).
    @State private var keepsAPIClient = false
    @State private var keepsWorkbench = false
    /// Araç çubuğundaki API Client öğeleri görünür mü. Moddan bir tur sonra
    /// izler (bkz. body): araç çubuğunu yeniden çizmek (~50 ms, ölçüldü) mod
    /// seçicinin tıklamasıyla aynı işleme düşmesin, başparmak animasyonu önce
    /// başlasın. Yapay gecikme değil: bir sonraki ana döngü turu.
    @State private var toolbarShowsAPIClient: Bool?

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

    /// Pencerenin üst ortasındaki mod seçici: sistemin segmentli kontrolü
    /// (cam başparmak, sürüklenebilir) + seçili modda yeşil nokta
    /// (`ModeSegmentedControl`, TASARIM §1 istisnası).
    private var modePicker: some View {
        @Bindable var state = appState
        return ModeSegmentedControl(selection: $state.mode)
            .fixedSize()
            .help(L10n.t("toolbar.mode.help"))
    }

    var body: some View {
        @Bindable var state = appState
        // İki mod bir kez kurulduktan sonra ikisi de canlı kalır, yalnızca
        // görünürlük değişir. Eskiden if/else her geçişte bir modun bütün
        // ağacını (liste, editörler, NSTextView'lar) yıkıp ötekini ana iş
        // parçacığında baştan kuruyordu: ölçüldü (debug, ekran dışı) hafif
        // içerikte ~100 ms, yoğun içerikte ~200–290 ms; mod seçicinin
        // animasyonu bu süre boyunca donuyordu. Gizli mod etkileşime ve
        // klavyeye kapalı (`modeLayer`); kaydırma, seçim ve imleç korunur.
        ZStack {
            if appState.isAPIClient || keepsAPIClient {
                APIClientLayout()
                    .modeLayer(visible: appState.isAPIClient)
            }
            if !appState.isAPIClient || keepsWorkbench {
                WorkbenchView()
                    .modeLayer(visible: !appState.isAPIClient)
            }
        }
        .onChange(of: appState.mode, initial: true) { _, mode in
            if mode == .apiClient { keepsAPIClient = true } else { keepsWorkbench = true }
            if toolbarShowsAPIClient == nil {
                // Açılışta hemen doğru durumda (titreme olmasın).
                toolbarShowsAPIClient = mode == .apiClient
            } else {
                DispatchQueue.main.async { toolbarShowsAPIClient = appState.mode == .apiClient }
            }
        }
        .onChange(of: appState.mode) {
            // Gizlenen moddaki editör klavyeyi almaya devam etmesin (eskiden
            // görünüm yıkıldığı için odak zaten düşüyordu).
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .task {
            // Öteki modu ilk geçişten önce, kullanıcı boştayken bir kez kur:
            // ilk geçiş de sonrakiler kadar hızlı olsun.
            try? await Task.sleep(for: .seconds(2))
            keepsAPIClient = true
            keepsWorkbench = true
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                modePicker
            }
            // Environment, geçmiş, çerez, TLS ve secret yalnızca API Client'ta
            // anlamlı; Workbench'te gizlenir (docs/V2.md). Kaldırılmaz, gizlenir:
            // her geçişte araç çubuğunu yeniden kurmak ~90 ms sürüyordu.
            APIClientOnly(isVisible: toolbarShowsAPIClient ?? appState.isAPIClient) {
                ToolbarItem(placement: .automatic) {
                    EnvironmentPicker()
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingEnvironments = true
                    } label: {
                        Label(L10n.t("toolbar.environments"), systemImage: "globe")
                    }
                    .help(L10n.t("toolbar.environments.help"))
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
                    Label(L10n.t("toolbar.appearance"), systemImage: appState.appearanceMode.icon)
                }
                .pickerStyle(.menu)
                // Diğer araç çubuğu düğmeleri gibi dar kalsın: seçenekler
                // zaten tıklayınca açılan listede.
                .menuIndicator(.hidden)
                .frame(width: 36)
                .help(L10n.t("toolbar.appearance.help"))
            }
            ToolbarItem(placement: .automatic) {
                LanguagePicker()
            }
            APIClientOnly(isVisible: toolbarShowsAPIClient ?? appState.isAPIClient) {
                toolbarGroupBreak
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingHistory = true
                    } label: {
                        Label(L10n.t("toolbar.history"), systemImage: "clock.arrow.circlepath")
                    }
                    .help(L10n.t("toolbar.history.help"))
                    .keyboardShortcut("y", modifiers: .command)
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingCookies = true
                    } label: {
                        Label {
                            Text(L10n.t("toolbar.cookies"))
                        } icon: {
                            CookieIcon().frame(width: 15, height: 15)
                        }
                    }
                    .help(L10n.t("toolbar.cookies.help"))
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
                        Label(L10n.t("toolbar.validationOff"), systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .foregroundStyle(Theme.down)
                    .help(L10n.t("toolbar.validationOff.help"))
                }
            }
            APIClientOnly(isVisible: toolbarShowsAPIClient ?? appState.isAPIClient) {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingTLS = true
                    } label: {
                        Label(L10n.t("toolbar.tls"), systemImage: "lock.shield")
                    }
                    .help(L10n.t("toolbar.tls.help"))
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingSecrets = true
                    } label: {
                        Label(L10n.t("toolbar.secrets"), systemImage: "key.fill")
                    }
                    .help(L10n.t("toolbar.secrets.help"))
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
                Button(L10n.t("common.revealInFinder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    state.dismissPresentedMessage()
                }
            }
            Button(L10n.t("common.ok")) { state.dismissPresentedMessage() }
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
        // Büyük harfe çevirme ve SwiftUI biçimleri seçili dile göre olsun
        // (Türkçede "BİÇİMLENDİRME", İngilizce ayarlı sistemde bile). Yalnızca
        // dil değişince güncellenir.
        .environment(\.locale, L10n.language.locale)
    }

}

private extension View {
    /// Mod katmanı: gizliyken görünmez ve tıklama ona ulaşmaz; ağaç canlı
    /// kalır. İçerideki klavye kısayolları modu `AppState`'ten okur.
    ///
    /// Bilinçli olarak `.disabled`, `.allowsHitTesting` ya da bir ortam
    /// (environment) değeri DEĞİL: değişince katmandaki her görünüme yayılıyor,
    /// her NSView sarmalayıcısı (`updateNSView`, büyük metinli editörler dahil)
    /// yeniden güncelleniyor. Ölçüldü (debug, yoğun içerik): geçiş başına
    /// 35–80 ms; yalnızca opaklık 3–16 ms. Tıklama, görünür katman üstte
    /// (zIndex) ve gizli katmanın üstünde saydam bir örtüyle engellenir.
    func modeLayer(visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .overlay {
                if !visible { Color.clear.contentShape(Rectangle()) }
            }
            .accessibilityHidden(!visible)
            .zIndex(visible ? 1 : 0)
    }
}

extension View {
    /// Yalnızca `mode` görünürken çalışan klavye kısayolu. İki mod da canlı
    /// tutulduğu için gizli moddaki ⌘↩, ⌘K, Esc… aksi halde çalışırdı.
    /// Modu kendi içinde okur: içeren görünümün gövdesi mod değişince yeniden
    /// hesaplanmasın (ölçüldü: istek editöründe ~20 ms fark).
    func keyboardShortcut(_ shortcut: KeyboardShortcut, onlyIn mode: AppMode) -> some View {
        modifier(ModeShortcut(shortcut: shortcut, mode: mode))
    }
}

private struct ModeShortcut: ViewModifier {
    /// İsteğe bağlı: mod bilgisi olmayan bir yerde (ör. testte tek başına
    /// çizilen Workbench) kısayol her zaman açık.
    @Environment(AppState.self) private var appState: AppState?
    let shortcut: KeyboardShortcut
    let mode: AppMode

    func body(content: Content) -> some View {
        content.keyboardShortcut(appState.map { $0.mode == mode } ?? true ? shortcut : nil)
    }
}

/// API Client'a özel araç çubuğu öğeleri. macOS 15+'ta Workbench'te gizlenir
/// (öğeler araç çubuğunda kalır): her mod geçişinde eklenip çıkarılınca
/// araç çubuğu yeniden kurulup çiziliyordu (ölçüldü, debug: API Client'a
/// dönüşte ~90 ms). macOS 14'te `hidden` yok; orada eskisi gibi kaldırılır.
private struct APIClientOnly<Content: ToolbarContent>: ToolbarContent {
    let isVisible: Bool
    @ToolbarContentBuilder let content: Content

    var body: some ToolbarContent {
        if #available(macOS 15.0, *) {
            content.hidden(!isVisible)
        } else if isVisible {
            content
        }
    }
}
