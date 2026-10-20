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

    /// Ayarlar çarkı sağda, environment seçicinin hemen solunda (kullanıcı
    /// isteği, 2026-10-20). Kendi camını çizdiği için ortak kapsül kapalı;
    /// seçiciyle arasındaki boşluk çarkın kendi çerçevesinde.
    @ToolbarContentBuilder
    private var settingsToolbarItem: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .automatic) { settingsButton.padding(.trailing, Self.settingsSpacing) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .automatic) { settingsButton.padding(.trailing, Self.settingsSpacing) }
        }
    }

    /// Geçmiş: çarkın solunda, aynı boşlukla (kullanıcı isteği, 2026-10-20).
    /// Çarkla aynı görünüm (28 pt cam daire); ortak kapsül kapalı, boşluk
    /// camın dışında. Yalnızca API Client'ta.
    @ToolbarContentBuilder
    private var historyToolbarItem: some ToolbarContent {
        APIClientOnly(isVisible: toolbarShowsAPIClient ?? appState.isAPIClient) {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .automatic) { historyButton }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .automatic) { historyButton }
            }
        }
    }

    private var historyButton: some View {
        let style = RadialMenuStyle()
        return Button {
            showingHistory = true
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: style.iconSize, weight: .semibold))
                .frame(width: style.itemDiameter, height: style.itemDiameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(ToolbarGlassCircle())
        .keyboardShortcut(KeyboardShortcut("y", modifiers: .command), onlyIn: .apiClient)
        .help(L10n.t("toolbar.history"))
        .accessibilityLabel(L10n.t("toolbar.history"))
        // Çarkla seçici arasındaki boşluk: camlar arası mesafe iki yanda eşit
        // (ölçüldü: 28.5 pt; çarkın halesi kendi çerçevesinde).
        .padding(.trailing, Self.settingsSpacing)
    }

    /// Çark ile environment seçicinin camı arasındaki ek boşluk (pt). 8'de
    /// seçici açılırken (etkileşimli cam basınca büyüyor) çarkın üstüne
    /// biniyordu (kullanıcı geri bildirimi, 2026-10-20).
    static let settingsSpacing: CGFloat = 16

    /// Environment seçici en sağda. Sağ kenara yapışmasın: soldaki pencere
    /// düğmelerinin kenar boşluğuyla dengelenecek kadar sabit boşluk.
    @ToolbarContentBuilder
    private var environmentToolbarItem: some ToolbarContent {
        APIClientOnly(isVisible: toolbarShowsAPIClient ?? appState.isAPIClient) {
            if #available(macOS 26.0, *) {
                // Ortak cam kapsülü kapatılıp aynı cam elle çizilir: boşluk
                // camın DIŞINDA kalsın (kapsülün içine eklenince seçici tek
                // yana büyüyordu).
                ToolbarItem(placement: .automatic) {
                    EnvironmentPicker()
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .padding(.trailing, Self.trailingInset)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .automatic) {
                    EnvironmentPicker()
                        .background(.quaternary, in: Capsule())
                        .padding(.trailing, Self.trailingInset)
                }
            }
        }
    }

    /// Ayarlar menüsünün öğeleri: tetikleyiciden sonra saat yönünde.
    /// Geçmiş, çerez ve secrets yalnızca API Client'ta anlamlı.
    private var settingsButton: some View {
        SettingsMenuButton(items: {
            var items = [
                RadialMenuItem(
                    id: "appearance", title: L10n.t("toolbar.appearance"),
                    value: appState.appearanceMode.label, closesMenu: false,
                    icon: AnyView(Image(systemName: appState.appearanceMode.icon))
                ) {
                    let all = AppearanceMode.allCases
                    let next = all[((all.firstIndex(of: appState.appearanceMode) ?? 0) + 1) % all.count]
                    appState.appearanceMode = next
                },
                RadialMenuItem(
                    id: "language", title: L10n.t("common.language"),
                    value: L10n.language.displayName, closesMenu: false,
                    // Metin simgeden optik olarak hafif: aynı oranda büyür (11 → 13).
                    icon: AnyView(Text(L10n.language == .turkish ? "TR" : "EN")
                        .font(.system(size: 13, weight: .bold, design: .rounded)))
                ) {
                    Localizer.shared.language = L10n.language == .turkish ? .english : .turkish
                },
            ]
            if toolbarShowsAPIClient ?? appState.isAPIClient {
                // Environment'lar menüde yok: seçicideki her satırın düzenle
                // düğmesi ve "Environment Ekle" o işi yapıyor.
                items += [
                    // Doğrulama kapalıyken TLS öğesinde de kırmızı işaret (asıl
                    // uyarı araç çubuğunda her an görünür kalır).
                    RadialMenuItem(id: "tls", title: L10n.t("toolbar.tls"),
                                   value: appState.certificateValidationDisabled ? L10n.t("toolbar.validationOff") : nil,
                                   icon: AnyView(TLSMenuIcon(validationOff: appState.certificateValidationDisabled))) { showingTLS = true },
                    RadialMenuItem(id: "cookies", title: L10n.t("toolbar.cookies"),
                                   icon: AnyView(CookieIcon().frame(width: 16, height: 16))) { showingCookies = true },
                    RadialMenuItem(id: "secrets", title: L10n.t("toolbar.secrets"),
                                   icon: AnyView(Image(systemName: "key.fill"))) { showingSecrets = true },
                ]
            }
            return items
        })
    }

    /// Environment seçicinin camının dışındaki sağ boşluk (pt). Araç
    /// çubuğunun kendi sağ boşluğuna (ortak cam kapalıyken 8) eklenir; toplam
    /// 19 = soldaki pencere düğmelerinin kenar boşluğu (ekran dışı ölçüm,
    /// 2026-10-20; görünür camın kenarına göre, metne göre değil).
    static let trailingInset: CGFloat = 11

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
            // Güvenlik durumu her modda görünür (docs/TASARIM.md §1): TLS
            // ayarları menüye taşındı ama doğrulama kapalıyken bu uyarı araç
            // çubuğunda kalır; açık unutulursa kullanıcı bunu bir yanıta
            // bakana kadar fark etmezdi. Tıklamak durumu DEĞİŞTİRMEZ, TLS
            // ayarlarını açar (kullanıcı isteği, 2026-10-20).
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
            // Sağda: Ayarlar çarkı, ardından en sağda environment seçici
            // (yalnızca API Client'ta; Workbench'te gizlenir, kaldırılmaz:
            // araç çubuğunu yeniden kurmak ~90 ms). Görünüm, dil,
            // environment'lar, TLS, geçmiş, çerez ve secrets dairesel menüde
            // (SettingsMenuButton).
            historyToolbarItem
            settingsToolbarItem
            environmentToolbarItem
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

/// TLS öğesinin simgesi: doğrulama kapalıyken köşede kırmızı işaret.
private struct TLSMenuIcon: View {
    let validationOff: Bool

    var body: some View {
        Image(systemName: "lock.shield")
            .overlay(alignment: .topTrailing) {
                if validationOff {
                    Circle().fill(Theme.down)
                        .frame(width: 6, height: 6)
                        .offset(x: 3, y: -2)
                }
            }
    }
}
