import AppKit
import SwiftUI

/// ------------------------------------------------------------------------
/// GEÇİCİ TIKLAMA TEŞHİSİ — kalıcı değil, SİLİNECEK.
///
/// Neden var: bir makinede (macOS 26) sidebar'da isteklere tıklamak için imleci
/// satırın altına kaydırmak gerekiyor. Accessibility izni olmayan makinelerde
/// dışarıdan ölçemiyoruz; bu yüzden uygulama KENDİ düzen çerçevelerini ve KENDİ
/// tıklama olaylarını kaydediyor. Hiçbir sistem izni gerektirmez.
///
/// Açmak için ortam değişkeni:
///   DEV2KIT_CLICK_DEBUG=1   -> tıklama/satır günlüğü
///   DEV2KIT_PLAIN_SIDEBAR=1 -> arama ve alt çubuk safeAreaInset yerine VStack
///                              (safeAreaInset kaynaklı kayma şüphesini test eder)
///
/// Değişken verilmediğinde hiçbir kod çalışmaz, davranış birebir aynıdır.
/// NE ZAMAN SİLİNECEK: tıklama sorunu kapanınca (TODO.md > "Geçici").
/// ------------------------------------------------------------------------
@MainActor
enum ClickDebug {
    static let isEnabled = ProcessInfo.processInfo.environment["DEV2KIT_CLICK_DEBUG"] == "1"
    static let plainSidebar = ProcessInfo.processInfo.environment["DEV2KIT_PLAIN_SIDEBAR"] == "1"

    /// Satırların en son çizilen çerçeveleri (pencere koordinatı, üst-sol orijin).
    /// Anahtar UUID: aynı adlı ("Yeni İstek") satırlar birbirini ezmesin.
    private static var frames: [UUID: (name: String, rect: CGRect)] = [:]
    private static var started = false

    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/dev2kit-teshis")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tiklama.log")
    }()

    static func start() {
        guard isEnabled, !started else { return }
        started = true
        // Dosya silinmez: birden fazla deneme (ör. DEV2KIT_PLAIN_SIDEBAR'lı ve
        // değil) tek dosyada, sırayla birikir.
        let info = ProcessInfo.processInfo
        write("=== dev2kit tıklama günlüğü — \(Date().formatted()) ===")
        write("macOS \(info.operatingSystemVersionString)")
        write("bundle: \(Bundle.main.bundleIdentifier ?? "YOK (swift run)")")
        write("ekran: \(NSScreen.main.map { "\($0.frame.size) ölçek \($0.backingScaleFactor)" } ?? "?")")
        write("plainSidebar: \(plainSidebar)")
        write("--- Sol listeden isteklere tıkla; her tıklama aşağıya yazılır. ---")
        // Local monitor: uygulamanın KENDİ olayları, sistem izni gerektirmez.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            handle(event)
            return event
        }
    }

    /// Satır çizilirken çerçevesini kaydeder.
    static func record(_ id: UUID, _ name: String, _ rect: CGRect) {
        guard isEnabled else { return }
        frames[id] = (name, rect)
    }

    /// Her sol tıklamada: olayın penceredeki yeri, AppKit'in hangi satırı
    /// gördüğü ve SwiftUI'nin o noktaya hangi satırı ÇİZDİĞİ yan yana yazılır.
    /// İkisi farklıysa "görünen yer" ile "tıklanan yer" kaymış demektir.
    private static func handle(_ event: NSEvent) {
        guard isEnabled, let window = event.window, let root = window.contentView else { return }
        let height = root.bounds.height
        let inWindow = event.locationInWindow                       // alt-sol orijin
        let topLeft = CGPoint(x: inWindow.x, y: height - inWindow.y) // üst-sol orijin
        write("")
        write("TIK  pencere-içi (üstten)  x=\(Int(topLeft.x))  y=\(Int(topLeft.y))")

        if let hit = root.hitTest(inWindow) {
            write("  AppKit hitTest: \(type(of: hit))")
            if let table = enclosingTableView(hit) {
                let inTable = table.convert(inWindow, from: nil)
                let row = table.row(at: inTable)
                write("  NSTableView satır indeksi: \(row)")
                if row >= 0 {
                    let rect = table.convert(table.rect(ofRow: row), to: nil)
                    let top = height - (rect.origin.y + rect.height)
                    write("  o satırın AppKit çerçevesi (üstten): y \(Int(top))–\(Int(top + rect.height))")
                }
            }
        }

        let cizilen = frames.values.first { $0.rect.contains(topLeft) }
        write("  SwiftUI bu noktaya ÇİZDİĞİ satır: \(cizilen.map { "\"\($0.name)\" y \(Int($0.rect.minY))–\(Int($0.rect.maxY))" } ?? "— (satır dışı)")")
        if let yakin = frames.values.min(by: { abs($0.rect.midY - topLeft.y) < abs($1.rect.midY - topLeft.y) }) {
            write("  en yakın çizilen satır: \"\(yakin.name)\" merkez y=\(Int(yakin.rect.midY)) — fark \(Int(topLeft.y - yakin.rect.midY))")
        }
    }

    private static func enclosingTableView(_ view: NSView) -> NSTableView? {
        var current: NSView? = view
        while let candidate = current {
            if let table = candidate as? NSTableView { return table }
            current = candidate.superview
        }
        return nil
    }

    /// Tıklamadan sonra gerçekten seçilen satır.
    static func selected(_ name: String?) {
        guard isEnabled else { return }
        write("  SEÇİLEN: \(name.map { "\"\($0)\"" } ?? "—")")
    }

    private static func write(_ line: String) {
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

// MARK: - Geçici sondalar (yalnızca ortam değişkeni açıkken devrede)

/// Satırın çizilen çerçevesini kaydeder; düzen ve tıklama aynı koordinat
/// uzayında karşılaştırılabilsin diye.
struct RowProbe: View {
    let id: UUID
    let name: String

    var body: some View {
        if ClickDebug.isEnabled {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { ClickDebug.record(id, name, geometry.frame(in: .global)) }
                    .onChange(of: geometry.frame(in: .global)) { _, new in
                        ClickDebug.record(id, name, new)
                    }
            }
        }
    }
}

/// Arama ve alt çubuk yerleşimi. Varsayılan `safeAreaInset`; ortam değişkeni
/// DEV2KIT_PLAIN_SIDEBAR=1 ile düz `VStack`. İkisi arasındaki fark, kaymanın
/// safeAreaInset'ten gelip gelmediğini gösterir.
struct SidebarChrome: ViewModifier {
    let search: AnyView
    let bottom: AnyView

    @ViewBuilder
    func body(content: Content) -> some View {
        if ClickDebug.plainSidebar {
            VStack(spacing: 0) {
                search
                content
                bottom
            }
        } else {
            content
                .safeAreaInset(edge: .top, spacing: 0) { search }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottom }
        }
    }
}
