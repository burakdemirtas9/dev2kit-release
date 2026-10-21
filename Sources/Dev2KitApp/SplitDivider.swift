import AppKit
import SwiftUI
import Dev2KitCore

/// Yeniden boyutlandırılabilir panel ayracı (kenar çubuğu, istek/yanıt,
/// Workbench girdi/çıktı, Geçmiş; 2026-10-21).
///
/// Görünen: 1 pt çizgi + ortada küçük tutamaç; hover/sürüklemede hafifçe
/// belirginleşir. Yakalama alanı ayraca dik yönde `thickness` (10 pt), tüm
/// uzunluk boyunca; kendi yerleşim yerini kaplar, komşu panellerin üstüne
/// binmez (editörlerin I-beam alanıyla çakışmaz).
///
/// Fare işini AppKit görünümü (`SplitHandleView`) yapar. Neden: SwiftUI
/// sürükleme hareketi + cursor rect'te imleç, fare 10 pt'lik alandan çıkınca
/// AppKit tarafından değiştiriliyordu (komşu editörün I-beam'i ya da ok);
/// `HSplitView` (NSSplitView) ayracının yakalama alanı da birkaç punto.
struct SplitDivider: View {
    /// Sürükleme yönü: `.horizontal` yan yana paneller (dikey çizgi, ↔),
    /// `.vertical` üst üste paneller (yatay çizgi, ↕).
    let axis: Axis
    /// Kenar çubuğu camlı zeminiyle ayrışıyor: çizgi yalnızca hover/sürüklemede.
    var showsLineAtRest = true
    /// Yakalama alanının zemini: komşu paneller kendi zeminini çiziyorsa
    /// (Workbench editörleri) aradaki şerit pencere zemini gibi görünmesin.
    var background: Color = .clear
    /// Sürükleme başladı (başlangıç boyutu burada saklanır).
    let onBegin: () -> Void
    /// Başlangıçtan beri yer değişimi: sağa / aşağı pozitif.
    let onChange: (CGFloat) -> Void
    var onEnd: () -> Void = {}

    static let thickness: CGFloat = 10

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        let active = isHovering || isDragging
        let vertical = axis == .horizontal
        ZStack {
            Rectangle()
                .fill(active ? Theme.accent.opacity(0.45) : Theme.tableLine)
                .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
                .opacity(showsLineAtRest || active ? 1 : 0)
            Capsule()
                .fill(active ? Theme.accent.opacity(0.85) : Color.secondary.opacity(0.35))
                .frame(width: vertical ? 3 : 28, height: vertical ? 28 : 3)
        }
        .frame(width: vertical ? Self.thickness : nil, height: vertical ? nil : Self.thickness)
        .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
        .background(background)
        .overlay {
            SplitHandle(
                axis: axis,
                onHover: { isHovering = $0 },
                onBegin: { isDragging = true; onBegin() },
                onChange: onChange,
                onEnd: { isDragging = false; onEnd() }
            )
        }
        .animation(.easeOut(duration: 0.12), value: active)
    }
}

/// İki panel yan yana, aralarında `SplitDivider` (`HSplitView` yerine).
/// Konum oran olarak tutulur: pencere boyutu değişince paneller orantılı
/// kalır; görünüm canlı olduğu sürece kullanıcının bıraktığı yer korunur
/// (`HSplitView`'daki gibi). İki panelin asgarisi pencerenin asgarisine katılır.
struct SplitPanes<First: View, Second: View>: View {
    let minFirst: CGFloat
    let minSecond: CGFloat
    var dividerBackground: Color = .clear
    let first: First
    let second: Second

    @State private var fraction: CGFloat
    @State private var dragStart: CGFloat?

    init(minFirst: CGFloat, minSecond: CGFloat, initialFraction: CGFloat = 0.5, dividerBackground: Color = .clear,
         @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.minFirst = minFirst
        self.minSecond = minSecond
        self.dividerBackground = dividerBackground
        self.first = first()
        self.second = second()
        _fraction = State(initialValue: initialFraction)
    }

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - SplitDivider.thickness)
            let width = SplitSizing.firstPane(fraction: fraction, available: available, minFirst: minFirst, minSecond: minSecond)
            HStack(spacing: 0) {
                first.frame(width: width)
                SplitDivider(axis: .horizontal, background: dividerBackground) {
                    dragStart = width
                } onChange: { delta in
                    let resized = SplitSizing.resized(start: dragStart ?? width, delta: delta,
                                                      lower: minFirst, upper: available - minSecond)
                    if available > 0 { fraction = resized / available }
                } onEnd: {
                    dragStart = nil
                }
                second.frame(maxWidth: .infinity)
            }
            // Sürüklerken örtük animasyon genişliği "kovalayınca" titriyor.
            .animation(nil, value: fraction)
        }
        .frame(minWidth: minFirst + minSecond + SplitDivider.thickness)
    }
}

/// Ayracın fare alanı: imleç, hover ve sürükleme.
private struct SplitHandle: NSViewRepresentable {
    let axis: Axis
    let onHover: (Bool) -> Void
    let onBegin: () -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> SplitHandleView { SplitHandleView() }

    func updateNSView(_ view: SplitHandleView, context: Context) {
        view.axis = axis
        view.onHover = onHover
        view.onBegin = onBegin
        view.onChange = onChange
        view.onEnd = onEnd
    }
}

/// - İmleç: alanında cursor rect (giriş/çıkışı AppKit yönetir; ayrılınca
///   resize imleci takılı kalmaz).
/// - Sürükleme: fare alandan çıksa da bitene kadar resize imleci korunur
///   (pencerenin cursor rect'leri o süre kapalı, her olayda imleç yeniden
///   konur). Bitince imleç farenin altındaki görünüme göre yeniden belirlenir.
/// - İlk yanıtlayıcı olmaz: editör odağını korur, metin seçimi tetiklenmez.
/// - Yer değişimi pencere koordinatında: ayraç kaydıkça geri besleme yok.
final class SplitHandleView: NSView {
    var axis: Axis = .horizontal {
        didSet { if oldValue != axis { window?.invalidateCursorRects(for: self) } }
    }
    var onHover: (Bool) -> Void = { _ in }
    var onBegin: () -> Void = {}
    var onChange: (CGFloat) -> Void = { _ in }
    var onEnd: () -> Void = {}

    private var dragStart: NSPoint?
    private weak var dragWindow: NSWindow?
    private var hoverArea: NSTrackingArea?

    var isDragging: Bool { dragStart != nil }
    var cursor: NSCursor { axis == .horizontal ? .resizeLeftRight : .resizeUpDown }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }

    override func mouseExited(with event: NSEvent) {
        if !isDragging { onHover(false) }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        dragWindow = window
        window?.disableCursorRects()
        cursor.set()
        onBegin()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        cursor.set()
        let point = event.locationInWindow
        // Pencere koordinatında y yukarı doğru artar; aşağı sürükleme pozitif.
        onChange(axis == .horizontal ? point.x - start.x : start.y - point.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        finishDrag()
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        onHover(inside)
        if inside {
            cursor.set()
        } else {
            // Bırakılan yere göre, sonraki hareketi beklemeden: metin alanında
            // I-beam, başka her yerde ok. (Alttaki görünüme `cursorUpdate`
            // bu olayla çağrılamıyor: NSTextView fare olayında istisna atıyor.)
            let target = window?.contentView?.hitTest(event.locationInWindow)
            (Self.isText(target) ? NSCursor.iBeam : NSCursor.arrow).set()
        }
        onEnd()
    }

    /// Metin girilebilen/seçilebilen görünüm (ya da onun içi: alan düzenleyicisi).
    static func isText(_ view: NSView?) -> Bool {
        var current = view
        while let view = current {
            if view is NSTextView { return true }
            if let field = view as? NSTextField { return field.isEditable || field.isSelectable }
            current = view.superview
        }
        return false
    }

    /// Sürükleme sırasında görünüm pencereden ayrılırsa cursor rect'ler
    /// kapalı kalmasın.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if isDragging { finishDrag(); onEnd() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func finishDrag() {
        dragStart = nil
        dragWindow?.enableCursorRects()
        dragWindow?.invalidateCursorRects(for: self)
        dragWindow = nil
    }
}
