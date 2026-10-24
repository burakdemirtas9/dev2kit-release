import AppKit
import SwiftUI
import Dev2KitCore

/// Araç çubuğunun solundaki dev2kit logosu (pencere başlığının yerinde).
///
/// Görsel kaynak seriden kırpıldı (saydam dış boşluk atıldı; hizalama
/// görünür içerikle) ve tam görüntüleme boyutunda 1× / 2× üretildi: AppKit
/// ekranın ölçeğine göre seçer, yeniden örnekleme yok (bulanıklaşmaz).
/// Açık görünümde beyaz yazı okunmadığı için yazısı koyulaştırılmış eşi
/// kullanılır; ikon ve turuncu devre aynı.
struct HeaderLogo: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    /// Görüntüleme boyutu (point). Yükseklik araç çubuğu denetimleriyle aynı
    /// ölçekte; araç çubuğunu uzatmaz. Genişlik görselin en-boy oranından.
    static let size = CGSize(width: 126.5, height: 28)

    var body: some View {
        Group {
            if let image = HeaderLogoImage.image(dark: colorScheme == .dark) {
                Image(nsImage: image)
                    .frame(width: Self.size.width, height: Self.size.height)
            } else {
                // Kaynak bulunamazsa eski başlık: boş görsel gösterilmez.
                Text("dev2kit").font(.headline)
            }
        }
        // Penceredeki sağ kenar: sol panelin asgari genişliği bundan. Yalnızca
        // büyür: tam ekranda pencere düğmeleri kalkınca logo sola kayar; asgari
        // de düşseydi panel girişte/çıkışta ~19 pt sıçrardı.
        .background {
            WindowEdgeReporter { edge in
                if edge > (appState.headerLogoTrailingEdge ?? 0) { appState.headerLogoTrailingEdge = edge }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("dev2kit")
        .accessibilityAddTraits(.isHeader)
    }
}

/// Logonun 1× ve 2× temsillerini tek `NSImage`'da toplar; görünüm başına
/// bir kez okunur, sonra bellekten.
@MainActor
enum HeaderLogoImage {
    private static var cache: [Bool: NSImage] = [:]

    static func image(dark: Bool) -> NSImage? {
        if let cached = cache[dark] { return cached }
        let name = dark ? "header-dark" : "header-light"
        let reps = [name, "\(name)@2x"].compactMap { file -> NSImageRep? in
            guard let url = resourceURL(file), let rep = NSImageRep(contentsOf: url) else { return nil }
            rep.size = HeaderLogo.size
            return rep
        }
        guard !reps.isEmpty else { return nil }
        let image = NSImage(size: HeaderLogo.size)
        reps.forEach(image.addRepresentation)
        cache[dark] = image
        return image
    }

    /// `.app` içinde `Bundle.main` (make-app.sh kopyalar); `Bundle.module`
    /// yalnızca bundle'sız çalışmada (bkz. `HTTPCatImages`).
    private static func resourceURL(_ name: String) -> URL? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Header")
        }
        return Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Header")
    }
}

/// Görünümün penceredeki sağ kenarını bildirir (pencere koordinatı, point).
/// Pencere değişince, yeniden yerleşince ve tam ekrana geçişte güncellenir.
/// macOS 14'te başlığı da gizler (15+ `toolbar(removing: .title)`).
private struct WindowEdgeReporter: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReporterView, context: Context) {
        view.onChange = onChange
    }

    final class ReporterView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var lastEdge: CGFloat?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if #unavailable(macOS 15) { window?.titleVisibility = .hidden }
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            report()
        }

        private func report() {
            guard window != nil else { return }
            let edge = convert(bounds, to: nil).maxX.rounded(.up)
            guard edge > 0, edge != lastEdge else { return }
            lastEdge = edge
            // Yerleşim sırasında SwiftUI durumunu yazma: bir tur sonra.
            DispatchQueue.main.async { [weak self] in self?.onChange?(edge) }
        }
    }
}

/// Başlık metni araç çubuğunda gösterilmez (yerinde logo). macOS 15+'te
/// SwiftUI'nin yolu; 14'te `WindowEdgeReporter` pencerenin başlığını gizler.
struct HidesWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
