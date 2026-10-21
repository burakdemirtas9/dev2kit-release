import AppKit
import SwiftUI

/// Görünümün sınırlarına bağlı imleç (AppKit cursor rect).
///
/// Neden `NSCursor.push()/pop()` değil (2026-10-21): `pop()` itme anındaki
/// imleci geri yüklüyor. Arama alanından (I-beam) ayraca gelip çıkınca I-beam
/// geri geliyordu; SwiftUI düğmelerinin kendi imleç alanı olmadığı için
/// Gönder gibi düğmelerin üstünde de öyle kalıyordu. Cursor rect'in girişini
/// ve çıkışını AppKit yönetir: yığın yok, bayat imleç geri yüklenmez,
/// görünüm kalkınca alan da kalkar.
///
/// Tıklamayı, hover'ı ve odağı etkilemez: `hitTest` her zaman `nil`,
/// ilk yanıtlayıcı olmaz.
struct CursorRegion: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorRegionView { CursorRegionView(cursor: cursor) }

    func updateNSView(_ view: CursorRegionView, context: Context) { view.cursor = cursor }
}

class CursorRegionView: NSView {
    var cursor: NSCursor {
        didSet { if oldValue !== cursor { window?.invalidateCursorRects(for: self) } }
    }

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    /// Yalnızca kendi sınırları: komşu görünümlere taşmaz.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }
}

extension View {
    /// Bu görünümün alanında `cursor` (bkz. `CursorRegion`).
    func cursorRegion(_ cursor: NSCursor) -> some View {
        background(CursorRegion(cursor: cursor))
    }
}
