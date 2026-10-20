import AppKit
import SwiftUI
import Dev2KitCore

/// `swift run` ile (bundle'sız) çalıştırıldığında macOS process'i tam bir GUI
/// uygulaması saymaz ve pencere klavye odağı alamaz (text field'lara yazılamaz).
/// Activation policy'yi elle .regular yapıp uygulamayı öne alarak düzeltiyoruz.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Kapanışta bekleyen (debounce'lanmış) workspace yazımını tamamlamak için.
    @MainActor var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // `swift run` ile bundle olmadığı için Dock ikonu elle atanır.
        // Gerçek .app bundle'da Info.plist zaten ikonu taşır.
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Kapanışta bekleyen yazım arka planda; bitmesini beklemek şart.
            appState?.waitForPendingWrites()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct Dev2KitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @State private var workbench = WorkbenchState()
    @AppStorage(EditorZoom.key) private var editorFontSize = EditorZoom.standard

    /// Workbench'teyken API Client'a ait kısayollar devre dışı (docs/V2.md).
    private var apiClientCommandsDisabled: Bool { !appState.isAPIClient }

    init() {
        // macOS'un akıllı tırnak/tire/metin düzeltmesi JSON ve header değerlerini
        // bozuyor (" → "). API istemcisinde her alan kod benzeri metin aldığı
        // için uygulama genelinde kapatılır. NSTextView bu ayarları oluşturulurken
        // okuduğundan, ilk view'dan önce (App.init) set edilmesi gerekir.
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "NSAutomaticQuoteSubstitutionEnabled")
        defaults.set(false, forKey: "NSAutomaticDashSubstitutionEnabled")
        defaults.set(false, forKey: "NSAutomaticTextReplacementEnabled")
        defaults.set(false, forKey: "NSAutomaticSpellingCorrectionEnabled")
        defaults.set(false, forKey: "NSAutomaticPeriodSubstitutionEnabled")
    }

    /// Menü çubuğundaki komutlar. Kısayollar buraya konur ki menüde görünür,
    /// yani keşfedilebilir olsunlar — görünmez kısayol yok sayılır.
    @CommandsBuilder
    private var appCommands: some Commands {
        // "New Window" yerine "Yeni İstek": tek pencereli, koleksiyon merkezli
        // bir araçta ⌘N'in beklenen anlamı yeni istektir (Postman/Insomnia da böyle).
        CommandGroup(replacing: .newItem) {
            Button(L10n.t("menu.newRequest")) {
                appState.addRequestToCurrentCollection()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(apiClientCommandsDisabled)
            Button(L10n.t("menu.newCollection")) {
                appState.addCollection()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(apiClientCommandsDisabled)
        }
        // ⌘W önce sekmeyi kapatır (Postman/Safari gibi); sekme yoksa pencereyi.
        // Standart "Kapat" bu grupta durduğu için grup değiştirilir.
        CommandGroup(replacing: .saveItem) {
            // Workbench diske yazmaz; ⌘S yalnızca bunu söyler (docs/V2.md).
            // API Client zaten her değişikliği kendiliğinden kaydediyor.
            Button(L10n.t("menu.save")) {
                workbench.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(appState.isAPIClient)
            Button(L10n.t("menu.closeTab")) {
                if let id = appState.selectedRequestID, appState.openTabs.contains(id) {
                    appState.closeTab(id)
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(apiClientCommandsDisabled)
            Button(L10n.t("menu.closeWindow")) {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        // Find, macOS'ta Düzen menüsünde yapıştırma grubundan sonra durur.
        CommandGroup(after: .pasteboard) {
            Divider()
            // ⌘F her modda odaktaki yerde arar: API Client'ta gövde ya da yanıt
            // editörüne tıklandıysa orada, değilse istek listesinde;
            // Workbench'te son tıklanan girdi/çıktıda.
            Button(L10n.t("menu.find")) {
                if appState.isAPIClient {
                    appState.findInAPIClient(firstResponder: NSApp.keyWindow?.firstResponder)
                } else {
                    workbench.requestSearch()
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            // Editöre tıklamadan da açılabilsin diye iki ayrı komut daha:
            // gövde ve yanıt birbirinden bağımsız aranır.
            Button(L10n.t("menu.findInBody")) {
                appState.openBodySearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(apiClientCommandsDisabled)
            Button(L10n.t("menu.findInResponse")) {
                appState.openResponseSearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(apiClientCommandsDisabled)
        }
        // Kod editörlerinin yazı boyutu: iki modda da (gövde, yanıt, Workbench).
        CommandGroup(after: .toolbar) {
            Divider()
            // Arayüz dili: anında uygulanır, tercih saklanır (L10n / Localizer).
            Picker(L10n.t("menu.language"), selection: Binding(
                get: { Localizer.shared.language },
                set: { Localizer.shared.language = $0 }
            )) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
            }
            Divider()
            Button(L10n.t("menu.zoomIn")) { editorFontSize = EditorZoom.zoomed(editorFontSize, by: 1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(editorFontSize >= EditorZoom.range.upperBound)
            Button(L10n.t("menu.zoomOut")) { editorFontSize = EditorZoom.zoomed(editorFontSize, by: -1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(editorFontSize <= EditorZoom.range.lowerBound)
            Button(L10n.t("menu.actualSize")) { editorFontSize = EditorZoom.standard }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(editorFontSize == EditorZoom.standard)
        }
        CommandMenu(L10n.t("menu.request")) {
            ForEach(Array(EditorTab.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.rawValue) {
                    appState.editorTab = tab
                }
                // ⌘1…⌘5 — sekme sayısı 9'u geçmediği sürece güvenli.
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                // Token sekmesi yalnızca Token Factory isteklerinde var.
                .disabled(tab == .token && !(appState.selectedRequestID.map(appState.isTokenFactoryRequest) ?? false))
            }
            .disabled(appState.selectedRequestID == nil || apiClientCommandsDisabled)
            Divider()
            // Ok tuşları klavye düzeninden bağımsız: ⇧⌘] Türkçe klavyede ⇧⌘Ü görünürdü.
            Button(L10n.t("menu.nextTab")) { appState.selectAdjacentTab(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(appState.openTabs.count < 2 || apiClientCommandsDisabled)
            Button(L10n.t("menu.previousTab")) { appState.selectAdjacentTab(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(appState.openTabs.count < 2 || apiClientCommandsDisabled)
            Divider()
            Button(L10n.t("menu.resetApprovals")) {
                confirmResetSecurityApprovals()
            }
        }
    }

    /// Onaylar kalıcı olduğu için geri almanın da bir yolu olmalı.
    private func confirmResetSecurityApprovals() {
        let alert = NSAlert()
        alert.messageText = L10n.t("approvals.reset.title")
        alert.informativeText = L10n.t("approvals.reset.message")
        alert.addButton(withTitle: L10n.t("approvals.reset.confirm"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try appState.resetSecurityApprovals()
        } catch {
            // Sistem hata metni bağlamsız ve İngilizce kalabiliyordu.
            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = L10n.t("approvals.reset.failed")
            failure.informativeText = L10n.t("approvals.reset.failedDetail", error.localizedDescription)
            failure.addButton(withTitle: L10n.t("common.ok"))
            failure.runModal()
        }
    }

    var body: some Scene {
        WindowGroup("dev2kit") {
            ContentView()
                .environment(appState)
                .environment(workbench)
                .tint(Theme.accent)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    appDelegate.appState = appState
                    SidebarDoubleClick.install {
                        // Workbench'in araç listesi de bir List: çift tık orada
                        // API Client sekmesine dokunmasın.
                        guard appState.isAPIClient else { return }
                        if let id = appState.selectedRequestID { appState.pinTab(id) }
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .commands { appCommands }
    }
}
