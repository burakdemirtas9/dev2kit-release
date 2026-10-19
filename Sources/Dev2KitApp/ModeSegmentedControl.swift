import AppKit
import SwiftUI

/// Pencerenin üst ortasındaki mod seçici: SİSTEMİN segmentli kontrolü
/// (macOS 26'da cam başparmak, sürükleyerek de kaydırılır) + seçili modun
/// önünde yeşil nokta (kullanıcı isteği, 2026-10-19).
///
/// Neden böyle (ölçülerek, ekran dışında çizilip): SwiftUI'nin segmentli
/// seçicisi metinli segmentte görüntüyü tamamen atıyor; AppKit'in kontrolü
/// görüntüyü gösteriyor ama her zaman TEK RENK (gri) boyuyor. Kendi
/// düğmelerimiz ise sürüklenemiyor ve camı zayıf kalıyordu. Çözüm: sistem
/// kontrolü olduğu gibi; her segmentte metinden önce nokta kadar boş yer
/// (saydam görüntü), seçili segmentin o yerine ayrı bir yeşil nokta katmanı.
struct ModeSegmentedControl: NSViewRepresentable {
    @Binding var selection: AppMode

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> DottedSegmentedControl {
        let control = DottedSegmentedControl(
            labels: AppMode.allCases.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:))
        )
        control.segmentDistribution = .fillEqually
        for index in AppMode.allCases.indices {
            control.setImage(DottedSegmentedControl.spacer, forSegment: index)
            control.setImageScaling(.scaleNone, forSegment: index)
        }
        control.setAccessibilityLabel("Mod")
        control.toolTip = "API Client ile Workbench arasında geç"
        return control
    }

    func updateNSView(_ control: DottedSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let index = AppMode.allCases.firstIndex(of: selection) ?? 0
        if control.selectedSegment != index { control.selectedSegment = index }
        control.needsLayout = true
    }

    final class Coordinator: NSObject {
        var selection: Binding<AppMode>
        init(selection: Binding<AppMode>) { self.selection = selection }

        @objc func changed(_ sender: NSSegmentedControl) {
            guard AppMode.allCases.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = AppMode.allCases[sender.selectedSegment]
            (sender as? DottedSegmentedControl)?.needsLayout = true
        }
    }
}

final class DottedSegmentedControl: NSSegmentedControl {
    static let dotSize: CGFloat = 6
    /// Noktanın yeri: metinden önce boş görüntü (kontrol onu tek renk boyar
    /// ama saydam olduğu için görünmez).
    /// Nokta + metinle arası; sistem görüntü ile metin arasını dar bırakıyor.
    static let spacerWidth: CGFloat = dotSize + 3
    static let spacer: NSImage = {
        let image = NSImage(size: NSSize(width: spacerWidth, height: dotSize))
        image.isTemplate = true
        return image
    }()

    private let dot: NSView = {
        let view = DotView()
        view.wantsLayer = true
        view.layer?.cornerRadius = DottedSegmentedControl.dotSize / 2
        return view
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }

    override func layout() {
        super.layout()
        dot.layer?.backgroundColor = NSColor(Theme.up).cgColor
        guard segmentCount > 0, selectedSegment >= 0 else { dot.isHidden = true; return }
        dot.isHidden = false
        // Eşit genişlikli segmentler: içerik (nokta yeri + boşluk + metin)
        // segmentin ortasında.
        let segmentWidth = bounds.width / CGFloat(segmentCount)
        let label = label(forSegment: selectedSegment) ?? ""
        let textWidth = (label as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width
        let contentWidth = Self.spacerWidth + Self.imageGap + textWidth
        let x = segmentWidth * CGFloat(selectedSegment) + (segmentWidth - contentWidth) / 2
        dot.frame = NSRect(x: x.rounded(), y: ((bounds.height - Self.dotSize) / 2).rounded(), width: Self.dotSize, height: Self.dotSize)
    }

    /// Görüntü ile metin arasındaki boşluk (sistem çiziminden ölçülerek).
    static var imageGap: CGFloat = 4

    /// Tıklama ve sürükleme kontrolden geçsin: nokta olayları yutmaz.
    private final class DotView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
