import AppKit
import SwiftUI
import BoltDockCore

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
            appState?.flushPendingWrites()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct BoltDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

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
            Button("Yeni Koleksiyon") {
                appState.addCollection()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        // Find, macOS'ta Düzen menüsünde yapıştırma grubundan sonra durur.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("İstek Ara") {
                appState.focusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        CommandMenu("İstek") {
            ForEach(Array(EditorTab.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.rawValue) {
                    appState.editorTab = tab
                }
                // ⌘1…⌘4 — sekme sayısı 9'u geçmediği sürece güvenli.
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            .disabled(appState.selectedRequestID == nil)
        }
    }

    var body: some Scene {
        WindowGroup("BoltDock") {
            ContentView()
                .environment(appState)
                .tint(Theme.accent)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { appDelegate.appState = appState }
        }
        .windowResizability(.contentMinSize)
        .commands { appCommands }
    }
}
