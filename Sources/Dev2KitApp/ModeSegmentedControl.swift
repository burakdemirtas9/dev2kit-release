import AppKit
import SwiftUI
import Dev2KitCore

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
    /// Mocker segmentindeki yayın simgesi (Mocker çalışırken).
    var mockerIndicator: MockerModeIndicator = .hidden

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
        control.setAccessibilityLabel(L10n.t("toolbar.mode"))
        control.toolTip = L10n.t("toolbar.mode.help")
        return control
    }

    func updateNSView(_ control: DottedSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let index = AppMode.allCases.firstIndex(of: selection) ?? 0
        if control.selectedSegment != index { control.selectedSegment = index }
        control.needsLayout = true
        // Dil değişince ipucu ve erişilebilirlik adı da güncellensin.
        control.toolTip = L10n.t("toolbar.mode.help")
        control.setAccessibilityLabel(L10n.t("toolbar.mode"))
        control.mockerIndicator = mockerIndicator
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

    /// Mocker segmentindeki yayın simgesi. Noktayla aynı yöntem: kontrolün
    /// üstünde ayrı katman (sistem kontrolü segment görüntüsünü tek renge boyuyor).
    private let statusIcon: NSImageView = {
        let view = PassThroughImageView()
        view.imageScaling = .scaleNone
        return view
    }()
    static let statusIconSize: CGFloat = 12
    /// Simge ile metin arası ve simgenin yer ayırdığı boşluk (etiketin sonuna).
    static let statusIconGap: CGFloat = 4
    static let statusReserve = "\u{2002}\u{2002}\u{2002}"

    var mockerIndicator: MockerModeIndicator = .hidden {
        didSet {
            guard mockerIndicator != oldValue else { return }
            applyMockerIndicator()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(dot)
        addSubview(statusIcon)
        statusIcon.isHidden = true
    }

    private var mockerSegment: Int? {
        AppMode.allCases.firstIndex(of: .mocker).flatMap { $0 < segmentCount ? $0 : nil }
    }

    /// Simge görünürken etikete yer ayrılır (içerik segmentte ortalı kalsın),
    /// simge ve ipucu durumu söyler; gizliyken etiket eski haline döner.
    private func applyMockerIndicator() {
        guard let segment = mockerSegment else { return }
        let base = AppMode.mocker.title
        if let symbol = mockerIndicator.symbolName, let color = mockerIndicator.color {
            setLabel(base + Self.statusReserve, forSegment: segment)
            let configuration = NSImage.SymbolConfiguration(pointSize: Self.statusIconSize - 1, weight: .semibold)
            statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            statusIcon.contentTintColor = color
            statusIcon.isHidden = false
        } else {
            setLabel(base, forSegment: segment)
            statusIcon.isHidden = true
        }
        setToolTip(mockerIndicator.toolTip, forSegment: segment)
        invalidateIntrinsicContentSize()
        needsLayout = true
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
        layoutStatusIcon(segmentWidth: segmentWidth)
    }

    /// Simge "Mocker" yazısının hemen sağında, ayrılan boşlukta.
    private func layoutStatusIcon(segmentWidth: CGFloat) {
        guard !statusIcon.isHidden, let segment = mockerSegment else { return }
        let font = font ?? NSFont.systemFont(ofSize: 13)
        let label = (label(forSegment: segment) ?? "") as NSString
        let base = AppMode.mocker.title as NSString
        let contentWidth = Self.spacerWidth + Self.imageGap + label.size(withAttributes: [.font: font]).width
        let textStart = segmentWidth * CGFloat(segment) + (segmentWidth - contentWidth) / 2 + Self.spacerWidth + Self.imageGap
        let x = textStart + base.size(withAttributes: [.font: font]).width + Self.statusIconGap
        let size = Self.statusIconSize + 2
        statusIcon.frame = NSRect(x: x.rounded(), y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
    }

    /// Görüntü ile metin arasındaki boşluk (sistem çiziminden ölçülerek).
    static var imageGap: CGFloat = 4

    /// Tıklama ve sürükleme kontrolden geçsin: nokta olayları yutmaz.
    private final class DotView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class PassThroughImageView: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Mocker'ın mod seçicideki durumu: yeşil yayın simgesi çalışıyor, sarı
/// uygulanmamış değişiklik var, kırmızı üstü çizili başlatılamadı; durunca yok.
enum MockerModeIndicator: Equatable {
    case hidden
    case running(port: UInt16)
    case unapplied(port: UInt16)
    case failed(String)

    var symbolName: String? {
        switch self {
        case .hidden: return nil
        case .running, .unapplied: return "antenna.radiowaves.left.and.right"
        case .failed: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    var color: NSColor? {
        switch self {
        case .hidden: return nil
        case .running: return NSColor(Theme.up)
        case .unapplied: return NSColor(Theme.warning)
        case .failed: return NSColor(Theme.down)
        }
    }

    var toolTip: String? {
        switch self {
        case .hidden: return nil
        case .running(let port): return L10n.t("mocker.indicator.running", "localhost:\(port)")
        case .unapplied(let port): return L10n.t("mocker.indicator.unapplied", "localhost:\(port)")
        case .failed(let message): return message
        }
    }
}
