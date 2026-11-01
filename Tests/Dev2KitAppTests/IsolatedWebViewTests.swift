import Network
import WebKit
import XCTest
@testable import Dev2KitApp
import Dev2KitCore

/// Önizleme YALITIMINI ölçer.
///
/// Yanıt gövdesi güvenilmeyen içeriktir: izleme pikseli, dış script ya da
/// otomatik yönlendirme taşıyabilir. "Engelledik" demek yetmez — burada
/// gerçekten bir dinleyici açılıp hiçbir isteğin gelmediği doğrulanıyor.
@MainActor
final class IsolatedWebViewTests: XCTestCase {

    // MARK: - Gezinme politikası

    private func policy(for urlString: String?) async -> WKNavigationActionPolicy {
        let coordinator = IsolatedWeb.Coordinator()
        let action = StubNavigationAction(url: urlString.flatMap(URL.init(string:)))
        return await withCheckedContinuation { continuation in
            coordinator.webView(WKWebView(), decidePolicyFor: action) { decision in
                continuation.resume(returning: decision)
            }
        }
    }

    func testInitialLoadIsAllowed() async {
        // `loadHTMLString` about:blank olarak gelir.
        let decision = await policy(for: "about:blank")
        XCTAssertEqual(decision, .allow)
    }

    func testOutboundNavigationIsCancelled() async {
        for url in ["https://ornek.test/git", "http://127.0.0.1:1/x", "file:///etc/passwd"] {
            let decision = await policy(for: url)
            XCTAssertEqual(decision, .cancel, url)
        }
    }

    // MARK: - Dış kaynak yüklenmiyor

    func testRemoteResourcesAreNeverFetched() async throws {
        let port: UInt16 = 59321
        let listener = try RequestSpy(port: port)
        defer { listener.stop() }

        let html = """
        <html><body>
          <img src="http://127.0.0.1:\(port)/beacon.png">
          <script src="http://127.0.0.1:\(port)/kod.js"></script>
          <link rel="stylesheet" href="http://127.0.0.1:\(port)/stil.css">
          <iframe src="http://127.0.0.1:\(port)/cerceve"></iframe>
        </body></html>
        """

        let webView = try await loadInIsolation(html)
        XCTAssertNotNil(webView)
        // WebKit alt kaynakları yükleseydi bu süre içinde bağlantı gelirdi.
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(listener.connectionCount, 0, "önizleme dışarı çıktı")
    }

    func testPageScriptDoesNotRun() async throws {
        // Sayfa script'i çalışsaydı bu özniteliği eklerdi. Okuma, uygulama
        // tarafından çalıştırılan ayrı bir JS ile yapılıyor; sayfanın kendi
        // script'i kapalı olsa da bu yol açık.
        let html = """
        <html><body id="g"><script>document.getElementById('g').setAttribute('data-calisti','evet')</script></body></html>
        """
        let webView = try await loadInIsolation(html)
        let value = try? await webView.evaluateJavaScript(
            "document.getElementById('g').getAttribute('data-calisti')"
        )
        XCTAssertTrue(value == nil || value is NSNull, "sayfa script'i çalıştı: \(String(describing: value))")
    }

    // MARK: - Workbench önizlemesi (2026-11-01)

    /// Markdown önizlemesindeki dış görsel de yüklenmez.
    func testMarkdownPreviewNeverFetchesRemoteImages() async throws {
        let port: UInt16 = 59322
        let listener = try RequestSpy(port: port)
        defer { listener.stop() }
        let markdown = "![iz](http://127.0.0.1:\(port)/piksel.png)\n\n<img src=\"http://127.0.0.1:\(port)/ham.png\">"
        let webView = try await loadInIsolation(MarkdownRenderer.document(markdown))
        XCTAssertNotNil(webView)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(listener.connectionCount, 0, "önizleme dışarı çıktı")
    }

    /// Yazdıkça yeniden çizilen önizleme başa zıplamaz. Okuma ve geri verme
    /// uygulamanın betik dünyasında; sayfanın betikleri kapalıyken de çalışmalı.
    func testReloadKeepsTheScrollPosition() async throws {
        let tall = (1...300).map { "<p>satır \($0)</p>" }.joined()
        let coordinator = IsolatedWeb.Coordinator()
        let webView = IsolatedWeb.makeWebView(html: "<html><body>\(tall)</body></html>", coordinator: coordinator, drawsBackground: true)
        webView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .seconds(1))

        _ = try await webView.evaluateJavaScript("window.scrollTo(0, 600)", in: nil, contentWorld: .defaultClient)
        try await Task.sleep(for: .milliseconds(200))
        IsolatedWeb.load("<html><body><p>yeni</p>\(tall)</body></html>", into: webView, coordinator: coordinator, preservingScroll: true)
        try await Task.sleep(for: .seconds(1.5))

        let y = try await webView.evaluateJavaScript("window.scrollY", in: nil, contentWorld: .defaultClient) as? Double
        XCTAssertEqual(y ?? 0, 600, accuracy: 1, "yeniden yüklemede kaydırma yeri korunmalı")
        let text = try await webView.evaluateJavaScript("document.body.firstChild.textContent", in: nil, contentWorld: .defaultClient) as? String
        XCTAssertEqual(text, "yeni", "yeni içerik yüklendi")
    }

    /// `IsolatedWebView`'ı gerçek haliyle kurar ve yüklemeyi bekler.
    private func loadInIsolation(_ html: String) async throws -> WKWebView {
        let webView = IsolatedWeb.makeWebView(html: html, coordinator: IsolatedWeb.Coordinator())
        // Kural listesi derlemesi asenkron; yükleme ondan sonra başlıyor.
        try await Task.sleep(for: .seconds(1))
        return webView
    }
}

// MARK: - Yardımcılar

private final class StubNavigationAction: WKNavigationAction {
    private let stubRequest: URLRequest
    init(url: URL?) {
        self.stubRequest = url.map { URLRequest(url: $0) } ?? URLRequest(url: URL(string: "about:blank")!)
    }
    override var request: URLRequest { stubRequest }
}

/// Tek amacı "bağlantı geldi mi" saymak olan dinleyici.
private final class RequestSpy {
    private let listener: NWListener
    private let lock = NSLock()
    private var count = 0

    var connectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    init(port: UInt16) throws {
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.lock.lock()
            self?.count += 1
            self?.lock.unlock()
            connection.cancel()
        }
        listener.start(queue: .global())
    }

    func stop() { listener.cancel() }
}
