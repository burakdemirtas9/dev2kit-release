import AppKit
import PDFKit
import SwiftUI
import WebKit
import Dev2KitCore

/// Yanıtın "gerçekte nasıl göründüğü": HTML render edilir, görsel ve PDF
/// gösterilir. Hangi yanıtın önizlenebildiği kuralı Core'da
/// (`ResponsePreview`), burası yalnızca çizer.
struct ResponsePreviewView: View {
    let kind: ResponsePreview.Kind
    /// Sunucudan gelen ham byte'lar. `body` adı View protokolünde dolu.
    let payload: Data
    /// HTML'in HAM hali gösterilir, biçimlendirilmiş hali değil: girinti
    /// eklemek `<pre>` gibi boşluğa duyarlı içeriği bozar.
    let text: String?

    var body: some View {
        Group {
            if !ResponsePreview.isWithinLimit(payload) {
                unavailable(
                    L10n.t("preview.tooLarge.title"),
                    detail: L10n.t("preview.tooLarge.detail",
                                   ByteCountFormatter.string(fromByteCount: Int64(payload.count), countStyle: .binary),
                                   ByteCountFormatter.string(fromByteCount: Int64(ResponsePreview.sizeLimit), countStyle: .binary))
                )
            } else {
                switch kind {
                case .html:
                    if let text {
                        IsolatedWebView(html: text)
                    } else {
                        unavailable(L10n.t("preview.html.failed"), detail: L10n.t("preview.html.failed.detail"))
                    }
                case .image:
                    imagePreview
                case .pdf:
                    pdfPreview
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let image = NSImage(data: payload) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            }
        } else {
            unavailable(L10n.t("preview.image.failed"), detail: L10n.t("preview.image.failed.detail"))
        }
    }

    @ViewBuilder
    private var pdfPreview: some View {
        if let document = PDFDocument(data: payload) {
            PDFPreview(document: document)
        } else {
            unavailable(L10n.t("preview.pdf.failed"), detail: L10n.t("preview.pdf.failed.detail"))
        }
    }

    private func unavailable(_ title: String, detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "eye.slash", description: Text(detail))
    }
}

/// Ağa çıkmayan, script çalıştırmayan HTML görüntüleyici.
///
/// Yanıt gövdesi GÜVENİLMEYEN içeriktir: kullanıcının test ettiği bir uçtan
/// geliyor ve içinde izleme pikseli, dış script, otomatik yönlendirme
/// olabilir. Üç katmanla kapatılıyor:
///
/// 1. `allowsContentJavaScript = false` — script hiç çalışmaz.
/// 2. Her URL'i engelleyen bir `WKContentRuleList` — görsel, stil, font dahil
///    HİÇBİR dış kaynak yüklenmez. Kural listesi derlenemezse içerik
///    YÜKLENMEZ (kapalı tarafa düşer).
/// 3. `about:blank` dışındaki her gezinme iptal edilir — bağlantıya tıklamak
///    ya da `<meta refresh>` dışarı çıkaramaz.
///
/// Ayrıca `baseURL: nil` (göreli adresler çözülmez) ve kalıcı olmayan veri
/// deposu (çerez/önbellek diske yazılmaz).
///
/// Kurulum `IsolatedWeb`'te, SwiftUI `Context`inden bağımsız: yalıtımın
/// gerçekten çalıştığı testle ölçülüyor (`IsolatedWebViewTests`).
struct IsolatedWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> IsolatedWeb.Coordinator { IsolatedWeb.Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        IsolatedWeb.makeWebView(html: html, coordinator: context.coordinator)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        IsolatedWeb.load(html, into: webView, coordinator: context.coordinator)
    }
}

/// Yalıtılmış önizlemenin kurulumu. Ayrı tip: SwiftUI `Context`i testte
/// üretilemiyor, yalıtımın kendisi ise test edilmesi GEREKEN kısım.
enum IsolatedWeb {
    /// Her şeyi engelleyen kural listesi. Kimlik sabit: WebKit derlenmiş
    /// listeyi önbelleğe alıyor, her önizlemede yeniden derlenmesin.
    static let blockerIdentifier = "dev2kit-preview-block-all"
    static let blockerRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#

    @MainActor
    static func makeWebView(html: String, coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")

        load(html, into: webView, coordinator: coordinator)
        return webView
    }

    @MainActor
    static func load(_ html: String, into webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedHTML = html
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: blockerIdentifier,
            encodedContentRuleList: blockerRules
        ) { list, error in
            Task { @MainActor in
                guard let list, error == nil else {
                    // Engelleyici kurulamadıysa içerik GÖSTERİLMEZ: dış kaynak
                    // yüklenmesindense önizlemenin olmaması yeğdir.
                    coordinator.isBlockerInstalled = false
                    webView.loadHTMLString(blockedNotice, baseURL: nil)
                    return
                }
                webView.configuration.userContentController.removeAllContentRuleLists()
                webView.configuration.userContentController.add(list)
                coordinator.isBlockerInstalled = true
                webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }

    static var blockedNotice: String {
        "<html><body style=\"font: -apple-system-body; color: #888; padding: 24px\">"
            + L10n.t("preview.blocked") + "</body></html>"
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?
        /// Engelleyici kural listesi kuruldu mu. `IsolatedWeb` dışarıdan
        /// yazıyor; modül dışına kapalı.
        var isBlockerInstalled = false

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // `loadHTMLString` about:blank olarak gelir; başka her şey dışarıya
            // çıkma girişimidir ve iptal edilir.
            let isInitialLoad = navigationAction.request.url.map {
                $0.absoluteString == "about:blank"
            } ?? true
            decisionHandler(isInitialLoad ? .allow : .cancel)
        }
    }
}

/// PDF görüntüleyici. PDFKit'in kendi kaydırma ve yakınlaştırması kullanılır.
struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
