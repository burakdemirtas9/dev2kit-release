import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Kullanım kılavuzu (docs/tutorial) için ekran görüntüleri. Yalnızca
/// SHOTS_DIR verilince çalışır; örnek veri geçici dizinde, kullanıcının
/// workspace'ine dokunulmaz. Önce demo sunucusu açılır
/// (`docs/tutorial/tools/demo_server.py`, 127.0.0.1:8787); yakalama
/// `screencapture -l` ile yalnızca bu pencereyi alır (Ekran Kaydı izni ister).
/// Ayrıntı: docs/tutorial/README.md.
@MainActor
final class TutorialShotsTests: XCTestCase {
    private var outDir: URL!
    private var only: Set<String> = []

    override func invokeTest() { withLanguage(.turkish) { super.invokeTest() } }

    private func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func capture(_ window: NSWindow, _ name: String) {
        guard only.isEmpty || only.contains(where: { name.hasPrefix($0) }) else { return }
        window.displayIfNeeded()
        pump(0.6)
        let path = outDir.appendingPathComponent("\(name).png").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
        try? process.run()
        process.waitUntilExit()
    }

    private func makeWindow<V: View>(_ view: V, size: CGSize, title: String = "") -> (NSWindow, NSHostingController<V>) {
        let controller = NSHostingController(rootView: view)
        controller.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: size.width, height: size.height),
                              styleMask: ProcessInfo.processInfo.environment["SHOTS_NOFULL"] != nil ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = title
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        window.setContentSize(size)
        window.orderFrontRegardless()
        return (window, controller)
    }

    // MARK: - Örnek veri

    struct Sample {
        var users = UUID(), userDetail = UUID(), createUser = UUID(), updateUser = UUID(), deleteUser = UUID()
        var health = UUID(), orders = UUID(), token = UUID()
        var local = UUID(), test = UUID()
        var usersCollection = UUID(), ordersCollection = UUID()
    }

    private func seed(_ state: AppState) -> Sample {
        let s = Sample()
        let json = "application/json"
        let users = CollectionModel(id: s.usersCollection, name: "Kullanıcı Servisi", requests: [
            RequestModel(id: s.users, name: "Kullanıcıları Listele", method: .get, url: "{{baseUrl}}/api/v1/users?page=1&limit=20",
                         headers: [KeyValueEntry(key: "Accept", value: json)],
                         queryParams: [KeyValueEntry(key: "page", value: "1"), KeyValueEntry(key: "limit", value: "20")],
                         auth: .bearer(token: "{{token}}")),
            RequestModel(id: s.userDetail, name: "Kullanıcı Detayı", method: .get, url: "{{baseUrl}}/api/v1/users/{{userId}}",
                         headers: [KeyValueEntry(key: "Accept", value: json)], auth: .bearer(token: "{{token}}")),
            RequestModel(id: s.createUser, name: "Kullanıcı Oluştur", method: .post, url: "{{baseUrl}}/api/v1/users",
                         headers: [KeyValueEntry(key: "Content-Type", value: json),
                                   KeyValueEntry(key: "X-Api-Key", value: "{{secret:apiKey}}")],
                         body: .raw(content: """
                         {
                           // Yorum satırları yalnızca senin için: gönderilmez
                           "name": "Burak Demirtaş",
                           "email": "burak@example.com",
                           "role": "editor",
                           "active": true
                         }
                         """, contentType: json),
                         auth: .bearer(token: "{{token}}")),
            RequestModel(id: s.updateUser, name: "Kullanıcı Güncelle", method: .put, url: "{{baseUrl}}/api/v1/users/{{userId}}",
                         body: .raw(content: "{\n  \"role\": \"admin\"\n}", contentType: json)),
            RequestModel(id: s.deleteUser, name: "Kullanıcı Sil", method: .delete, url: "{{baseUrl}}/api/v1/users/{{userId}}"),
        ])
        let orders = CollectionModel(id: s.ordersCollection, name: "Sipariş Servisi", requests: [
            RequestModel(id: s.orders, name: "Siparişleri Getir", method: .get, url: "{{baseUrl}}/api/v1/orders?status=OPEN"),
            RequestModel(id: s.health, name: "Sağlık Kontrolü", method: .get, url: "{{baseUrl}}/api/v1/health"),
        ])
        var workspace = state.workspace
        let others = workspace.collections.filter { !$0.isRegular }
        workspace.collections = [users, orders] + others
        let factoryID = workspace.ensureTokenFactoryCollection()
        if let index = workspace.collections.firstIndex(where: { $0.id == factoryID }) {
            workspace.collections[index].requests = [
                RequestModel(id: s.token, name: "Giriş Token'ı", method: .post, url: "{{baseUrl}}/api/v1/auth/token",
                             headers: [KeyValueEntry(key: "Content-Type", value: json)],
                             body: .raw(content: "{\n  \"username\": \"demo\",\n  \"password\": \"{{secret:demoPassword}}\"\n}", contentType: json),
                             tokenOutput: TokenOutput(responseField: "access_token", variableName: "token")),
            ]
        }
        workspace.environments = [
            EnvironmentModel(id: s.local, name: "Local", variables: [
                KeyValueEntry(key: "baseUrl", value: "http://127.0.0.1:8787"),
                KeyValueEntry(key: "userId", value: "1"),
            ]),
            EnvironmentModel(id: s.test, name: "Test", variables: [
                KeyValueEntry(key: "baseUrl", value: "https://api.test.example.com"),
                KeyValueEntry(key: "userId", value: "42"),
            ]),
        ]
        workspace.activeEnvironmentID = s.local
        state.workspace = workspace
        try? state.secretStore.setSecret("demo-api-key-123", forName: "apiKey")
        try? state.secretStore.setSecret("demo-pass", forName: "demoPassword")
        state.invalidateSecretNames()
        return s
    }

    private func sendAndWait(_ state: AppState, _ id: UUID, approve: Bool = true) {
        guard let request = state.request(withID: id) else { return }
        state.send(request)
        waitForResponse(state)
        if approve, case .needsApproval(let findings) = state.responses[id] {
            state.approveAndSend(findings)
            waitForResponse(state)
        }
    }

    private func waitForResponse(_ state: AppState) {
        let end = Date().addingTimeInterval(8)
        pump(0.2)
        while Date() < end, state.isSending { pump(0.1) }
        pump(0.5)
    }

    /// Sayfa (sheet) görünümünü kendi penceresinde çizer ve yakalar.
    private func captureSheet<V: View>(_ view: V, _ name: String, size: CGSize, state: AppState, setup: () -> Void = {}) {
        guard only.isEmpty || only.contains(where: { name.hasPrefix($0) }) else { return }
        let controller = NSHostingController(rootView: view.environment(state).ignoresSafeArea())
        let window = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: size.width, height: size.height),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        let fitting = controller.view.fittingSize
        window.setContentSize(CGSize(width: fitting.width > 10 ? fitting.width : size.width,
                                     height: fitting.height > 10 ? fitting.height : size.height))
        window.orderFrontRegardless()
        setup()
        pump(1.2)
        capture(window, name)
        window.orderOut(nil)
    }

    // MARK: - Çekim

    func testTutorialShots() throws {
        guard let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] else { throw XCTSkip("yalnızca SHOTS_DIR ile") }
        outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        only = Set((ProcessInfo.processInfo.environment["SHOTS_ONLY"] ?? "").split(separator: ",").map(String.init))
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        UserDefaults.standard.removeObject(forKey: "workbenchTool")

        let harness = AppStateHarness()
        defer { harness.tearDown() }
        let state = harness.state
        state.mode = .apiClient
        let workbench = WorkbenchState()
        let size = CGSize(width: 1440, height: 880)

        // Başlarken
        let (window, _) = makeWindow(ContentView().environment(state).environment(workbench), size: size)
        defer { window.orderOut(nil) }
        pump(2.5)
        capture(window, "01-ilk-acilis")

        let s = seed(state)
        pump(1.0)
        capture(window, "02-koleksiyonlar")

        // Yeni request
        state.addRequest(to: s.ordersCollection)
        pump(1.0)
        capture(window, "03-yeni-request")
        if let id = state.selectedRequestID { state.deleteRequest(id) }

        // Request düzenleme
        state.showRequest(s.users)
        state.keepTab(s.users)
        state.editorTab = .params
        state.selectedRequestIDs = []
        pump(1.0)
        capture(window, "04-query")

        state.showRequest(s.createUser)
        state.keepTab(s.createUser)
        state.selectedRequestIDs = []
        state.editorTab = .headers
        pump(0.8)
        capture(window, "05-headers")
        state.editorTab = .body
        pump(0.8)
        capture(window, "06-body")
        state.editorTab = .auth
        pump(0.8)
        capture(window, "07-auth")

        // Environment, secret
        captureSheet(EnvironmentsView(), "08-environments", size: CGSize(width: 900, height: 560), state: state)
        captureSheet(SecretsView(), "09-secrets", size: CGSize(width: 760, height: 520), state: state)

        // Token Factory
        state.showRequest(s.token)
        state.keepTab(s.token)
        state.selectedRequestIDs = []
        state.editorTab = .token
        pump(0.8)
        capture(window, "10-token-factory")
        sendAndWait(state, s.token, approve: false)
        capture(window, "11-guvenlik-onayi")
        if case .needsApproval(let findings) = state.responses[s.token] {
            state.approveAndSend(findings)
            waitForResponse(state)
        }
        capture(window, "11b-token-yanit")

        // Gönder ve yanıt
        state.showRequest(s.users)
        state.selectedRequestIDs = []
        state.editorTab = .params
        sendAndWait(state, s.users)
        capture(window, "12-yanit")

        state.showRequest(s.createUser)
        state.selectedRequestIDs = []
        state.editorTab = .body
        sendAndWait(state, s.createUser)
        capture(window, "13-post-yanit")

        // Örnek olarak kaydet
        state.beginSavingExample(for: s.createUser)
        pump(1.0)
        state.commitPendingExample(name: "201 Created")
        pump(1.0)
        state.selectedRequestIDs = []
        capture(window, "14-ornek")

        // Sekmeler ve arama
        state.showRequest(s.orders)
        state.keepTab(s.orders)
        sendAndWait(state, s.orders)
        state.showRequest(s.health)
        sendAndWait(state, s.health)
        state.searchQuery = "kullanici"
        state.selectedRequestIDs = []
        pump(1.0)
        capture(window, "15-arama-sekmeler")
        state.searchQuery = ""

        // Geçmiş, TLS, içe aktarma
        captureSheet(HistoryView(), "16-gecmis", size: CGSize(width: 1000, height: 620), state: state)
        captureSheet(TLSSettingsView(), "17-tls", size: CGSize(width: 900, height: 640), state: state)
        captureSheet(CurlImportView(), "18-curl-import", size: CGSize(width: 760, height: 480), state: state)
        captureSheet(OpenAPIImportView(), "19-openapi-import", size: CGSize(width: 760, height: 520), state: state)
        captureSheet(PostmanImportView(), "20-postman-import", size: CGSize(width: 760, height: 520), state: state)

        // Workbench
        state.mode = .workbench
        workbench.select(toolID: "json")
        workbench.input = #"{"id":1,"name":"Burak Demirtaş","roles":["admin","editor"],"address":{"city":"İstanbul","zip":"34000"},"active":true}"#
        pump(1.5)
        capture(window, "21-wb-json")
        workbench.select(outputMode: .tree)
        pump(1.0)
        capture(window, "22-wb-json-agac")
        workbench.select(toolID: "jwt")
        workbench.input = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkJ1cmFrIERlbWlydGHFnyIsImV4cCI6MTk5OTk5OTk5OX0.c2lnbmF0dXJl"
        pump(1.2)
        capture(window, "23-wb-jwt")
        workbench.select(toolID: "json-to-java")
        workbench.input = #"{ "id": 42, "customer_name": "Burak Demirtaş", "total": 12.5, "address": { "city": "İstanbul" }, "items": [{ "sku": "A1", "qty": 1 }] }"#
        pump(1.2)
        capture(window, "24-wb-java")
        workbench.select(toolID: WorkbenchCatalog.diffCheckerID)
        workbench.diff.left = "{\n  \"name\": \"Burak\",\n  \"role\": \"editor\",\n  \"active\": true\n}"
        workbench.diff.right = "{\n  \"name\": \"Burak\",\n  \"role\": \"admin\",\n  \"active\": true,\n  \"team\": \"API\"\n}"
        pump(1.5)
        capture(window, "25-wb-diff")
        workbench.select(toolID: "html-viewer")
        workbench.select(actionID: "preview")
        workbench.input = """
        <!DOCTYPE html>
        <html>
        <head>
          <style>
            body { font-family: -apple-system, sans-serif; margin: 28px; color: #1d2433; }
            .card { padding: 16px 20px; border: 1px solid #d5dbe5; border-radius: 10px; max-width: 420px; }
            .badge { display: inline-block; padding: 2px 10px; border-radius: 999px; background: #e3f6ea; color: #1f7a45; font-size: 12px; }
            td { padding: 4px 16px 4px 0; }
          </style>
        </head>
        <body>
          <div class="card">
            <h2>Sipariş #1042</h2>
            <span class="badge">Onaylandı</span>
            <table>
              <tr><td>Müşteri</td><td><b>Burak Demirtaş</b></td></tr>
              <tr><td>Tutar</td><td>1.250,00 ₺</td></tr>
              <tr><td>Teslimat</td><td>İstanbul</td></tr>
            </table>
          </div>
        </body>
        </html>
        """
        pump(2.0)
        capture(window, "27-wb-html")
        workbench.select(toolID: "markdown-viewer")
        workbench.select(actionID: "preview")
        workbench.input = """
        # Kullanıcı Servisi

        Kullanıcıları listeleyen ve güncelleyen **REST** servisi.

        ## Uç noktalar

        | Metot | Yol | Açıklama |
        |:------|:----|:---------|
        | GET | `/users` | Listeler |
        | POST | `/users` | Ekler |
        | DELETE | `/users/{id}` | Siler |

        ## Yapılacaklar

        - [x] Sayfalama
        - [x] Token doğrulama
        - [ ] Rate limit

        > Token, `{{secret:apiKey}}` ile gönderilir; değer koleksiyonda tutulmaz.
        """
        pump(2.0)
        capture(window, "28-wb-markdown")

        // Koyu tema
        state.mode = .apiClient
        window.appearance = NSAppearance(named: .darkAqua)
        state.showRequest(s.users)
        state.selectedRequestIDs = []
        pump(1.5)
        capture(window, "26-koyu-tema")
        window.appearance = NSAppearance(named: .aqua)
    }
}
