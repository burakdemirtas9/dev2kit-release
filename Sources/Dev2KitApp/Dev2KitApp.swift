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
            Button("Yeni İstek") {
                appState.addRequestToCurrentCollection()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(apiClientCommandsDisabled)
            Button("Yeni Koleksiyon") {
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
            Button("Save") {
                workbench.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(appState.isAPIClient)
            Button("Sekmeyi Kapat") {
                if let id = appState.selectedRequestID, appState.openTabs.contains(id) {
                    appState.closeTab(id)
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(apiClientCommandsDisabled)
            Button("Pencereyi Kapat") {
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
            Button(appState.isAPIClient ? "Ara" : "Find") {
                if appState.isAPIClient {
                    appState.findInAPIClient(firstResponder: NSApp.keyWindow?.firstResponder)
                } else {
                    workbench.requestSearch()
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            // Editöre tıklamadan da açılabilsin diye iki ayrı komut daha:
            // gövde ve yanıt birbirinden bağımsız aranır.
            Button("Gövdede Ara") {
                appState.openBodySearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(apiClientCommandsDisabled)
            Button("Yanıtta Ara") {
                appState.openResponseSearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(apiClientCommandsDisabled)
        }
        // Kod editörlerinin yazı boyutu: iki modda da (gövde, yanıt, Workbench).
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Yazıyı Büyüt") { editorFontSize = EditorZoom.zoomed(editorFontSize, by: 1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(editorFontSize >= EditorZoom.range.upperBound)
            Button("Yazıyı Küçült") { editorFontSize = EditorZoom.zoomed(editorFontSize, by: -1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(editorFontSize <= EditorZoom.range.lowerBound)
            Button("Gerçek Boyut") { editorFontSize = EditorZoom.standard }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(editorFontSize == EditorZoom.standard)
        }
        CommandMenu("İstek") {
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
            Button("Sonraki Sekme") { appState.selectAdjacentTab(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(appState.openTabs.count < 2 || apiClientCommandsDisabled)
            Button("Önceki Sekme") { appState.selectAdjacentTab(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(appState.openTabs.count < 2 || apiClientCommandsDisabled)
            Divider()
            Button("Güvenlik Onaylarını Sıfırla…") {
                confirmResetSecurityApprovals()
            }
        }
    }

    /// Onaylar kalıcı olduğu için geri almanın da bir yolu olmalı.
    private func confirmResetSecurityApprovals() {
        let alert = NSAlert()
        alert.messageText = "Güvenlik onayları sıfırlansın mı?"
        alert.informativeText = "“Yine de Gönder” ile onayladığın uyarılar unutulur; aynı durumlar yeniden sorulur."
        alert.addButton(withTitle: "Onayları Sıfırla")
        alert.addButton(withTitle: "Vazgeç")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try appState.resetSecurityApprovals()
        } catch {
            // Sistem hata metni bağlamsız ve İngilizce kalabiliyordu.
            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = "Güvenlik onayları sıfırlanamadı"
            failure.informativeText = "\(error.localizedDescription)\n\nOnayların değişmedi."
            failure.addButton(withTitle: "Tamam")
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
