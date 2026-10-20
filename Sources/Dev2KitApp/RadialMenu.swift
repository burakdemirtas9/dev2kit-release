import SwiftUI
import Dev2KitCore

/// Dairesel menünün bir öğesi. Tetikleyici (Ayarlar) bu listede değil;
/// `RadialMenuView` onu kendisi çizer ve sayıya katar.
struct RadialMenuItem: Identifiable {
    let id: String
    /// Erişilebilirlik adı ve ipucu.
    let title: String
    /// Erişilebilirlik değeri ("Koyu", "Türkçe"); yoksa `nil`.
    var value: String?
    /// Seçilince menü kapansın mı (sheet açan öğeler kapatır; görünüm/dil
    /// gibi yerinde değişen ayarlar menüyü açık bırakır).
    var closesMenu = true
    let icon: AnyView
    let action: () -> Void
}

/// Boyutlar ve zamanlama; hepsi dışarıdan ayarlanabilir.
struct RadialMenuStyle {
    /// Tüm öğelerin (tetikleyici dahil) çapı. Tıklama hedefi ≥ 22 pt.
    var itemDiameter: CGFloat = 28
    var iconSize: CGFloat = 13
    /// Görünmeyen çemberin yarıçapı. Öğeler çakışmasın diye en az
    /// `RadialMenuLayout.minimumRadius` kadar olmalı.
    var radius: CGFloat = 52
    /// Yolun kavisi (0 düz, 1 çember yayı).
    var curvature: Double = 0.35
    /// Doğuş ölçeği (nokta).
    var minimumScale: Double = 0.12
    /// Öğeler arası gecikme (90–110 ms).
    var stagger: Duration = .milliseconds(100)
    /// Öğe başına yerleşme: spring tepki süresi ve sönüm. 0.6 / 0.82 ile
    /// ~600 ms'de oturur, çok hafif aşma, titreşim yok.
    var springResponse: Double = 0.6
    var springDamping: Double = 0.82
    /// Yakın cam öğeler bu mesafede kısa bir sıvı bağ kurar (ayrılırken);
    /// son durumda öğeler arası boşluk bundan büyük olduğu için ayrı görünür.
    var glassSpacing: CGFloat = 10
    /// Panel kenarında gölge/ışıma payı.
    var margin: CGFloat = 8
}

/// Menünün durumu ve öğe başına ilerleme (0 kapalı, 1 yerleşmiş).
///
/// Zamanlama burada: her öğe ayrı bir spring ile hedefine gider, öğeler
/// `stagger` aralıkla başlar ve hareketleri örtüşür. Yön değişimi (açılırken
/// kapat, kapanırken aç) yeni hedefi aynı değere yazar; SwiftUI animasyonu
/// o anki görsel konumdan ve hızdan devam ettirir, sıçrama olmaz. Bekleyen
/// gecikmeli adımlar iptal edilir; eski bir açılma kapanıştan sonra
/// çalışamaz (`generation`).
@MainActor
@Observable
final class RadialMenuModel {
    enum Phase: Equatable {
        case closed, opening, open, closing
    }

    private(set) var phase: Phase = .closed
    /// Öğe başına ilerleme; indeks 0 tetikleyici (hep 1).
    private(set) var progress: [Double] = [1]
    /// Tamamen kapanınca (son öğe tetikleyiciye döndü).
    var onFullyClosed: (() -> Void)?

    private var targets: [Double] = [1]
    /// Animasyonu sürmekte olan öğeler.
    private var inFlight: Set<Int> = []
    /// Gecikmesi henüz dolmamış (başlamamış) öğe sayısı.
    private var pendingStarts = 0
    private var task: Task<Void, Never>?
    private var generation = 0

    var isExpanded: Bool { phase == .opening || phase == .open }

    /// Öğe sayısı (tetikleyici dahil). Yalnızca kapalıyken değişir.
    func prepare(count: Int) {
        guard phase == .closed, progress.count != count else { return }
        progress = Array(repeating: 0, count: count)
        progress[0] = 1
        targets = progress
    }

    func toggle(_ timing: RadialMenuTiming) {
        isExpanded ? close(timing) : open(timing)
    }

    func open(_ timing: RadialMenuTiming) {
        let layout = RadialMenuLayout(count: progress.count, radius: 1)
        // Kapanmakta olanlar hemen geri döner (görsel konumundan), henüz
        // başlamamış ya da tamamen kapanmış olanlar sırayla.
        let reversing = layout.openingOrder.filter { inFlight.contains($0) && targets[$0] == 0 }
        let rest = layout.openingOrder.filter { !reversing.contains($0) && targets[$0] == 0 }
        run(order: reversing, then: rest, target: 1, phase: .opening, timing: timing)
    }

    func close(_ timing: RadialMenuTiming) {
        let layout = RadialMenuLayout(count: progress.count, radius: 1)
        // Son açılan ilk kapanır; hiç başlamamış öğeye dokunulmaz.
        let started = layout.closingOrder.filter { targets[$0] == 1 }
        run(order: [], then: started, target: 0, phase: .closing, timing: timing)
    }

    /// Animasyonsuz, hemen kapalı (pencere kapandı, mod değişti, uygulama
    /// arka plana geçti). Bekleyen her şey iptal.
    func reset() {
        task?.cancel()
        generation += 1
        inFlight = []
        pendingStarts = 0
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            for index in progress.indices.dropFirst() { progress[index] = 0 }
        }
        targets = progress
        if phase != .closed {
            phase = .closed
            onFullyClosed?()
        }
    }

    private func run(order first: [Int], then staggered: [Int], target: Double, phase newPhase: Phase, timing: RadialMenuTiming) {
        task?.cancel()
        generation += 1
        let generation = generation
        phase = newPhase
        // Tıklamaya hemen karşılık: ilk adım (ters dönenler ya da sıradaki
        // ilk öğe) eşzamanlı başlar, gerisi `stagger` aralıkla.
        var immediate = first
        var delayed = staggered
        if immediate.isEmpty, !delayed.isEmpty { immediate = [delayed.removeFirst()] }
        pendingStarts = delayed.count
        for index in immediate { animate(index, to: target, timing: timing, generation: generation) }
        guard !delayed.isEmpty else {
            task = nil
            finishIfSettled(generation: generation)
            return
        }
        task = Task { @MainActor [weak self] in
            for index in delayed {
                try? await Task.sleep(for: timing.stagger)
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.pendingStarts -= 1
                self.animate(index, to: target, timing: timing, generation: generation)
            }
        }
    }

    private func animate(_ index: Int, to target: Double, timing: RadialMenuTiming, generation: Int) {
        targets[index] = target
        inFlight.insert(index)
        // Açılışta "mantıksal olarak bitti" yeterli (öğe yerinde), kapanışta
        // tamamen bitmeli: panel ancak son öğe tetikleyiciye girince gizlenir.
        let criteria: AnimationCompletionCriteria = target == 1 ? .logicallyComplete : .removed
        withAnimation(timing.animation, completionCriteria: criteria) {
            progress[index] = target
        } completion: { [weak self] in
            guard let self, self.generation == generation, self.targets[index] == target else { return }
            self.inFlight.remove(index)
            self.finishIfSettled(generation: generation)
        }
    }

    /// Hepsi başladı ve hepsi oturdu: açılış ya da kapanış bitti.
    private func finishIfSettled(generation: Int) {
        guard self.generation == generation, pendingStarts == 0, inFlight.isEmpty else { return }
        switch phase {
        case .opening:
            phase = .open
        case .closing:
            phase = .closed
            onFullyClosed?()
        case .open, .closed:
            break
        }
    }
}

/// Animasyonun kendisi; Reduce Motion açıkken sadeleşir.
struct RadialMenuTiming {
    let animation: Animation
    let stagger: Duration

    init(style: RadialMenuStyle, reduceMotion: Bool) {
        if reduceMotion {
            // Kavis ve yaylanma yok; kısa, düz bir geçiş.
            animation = .easeOut(duration: 0.18)
            stagger = .milliseconds(25)
        } else {
            animation = .spring(response: style.springResponse, dampingFraction: style.springDamping)
            stagger = style.stagger
        }
    }
}

/// Açık menü: tetikleyici tepede, öğeler saat yönünde. Kapalıyken yalnızca
/// tetikleyici görünür; gizli öğeler tıklama, klavye ve erişilebilirlik
/// odağı almaz.
///
/// Tetikleyicinin merkezi görünümün `anchor` noktasıdır (sol üstten); bu
/// görünüm onu çağıranın tam üstüne hizalanacak şekilde boyutlanır
/// (`RadialMenuView.canvas`).
struct RadialMenuView: View {
    let model: RadialMenuModel
    let items: [RadialMenuItem]
    let style: RadialMenuStyle
    let triggerTitle: String
    let closeTitle: String
    let triggerIcon: String
    let closeIcon: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNamespace

    /// Panelin boyutu ve tetikleyicinin içindeki yeri.
    static func canvas(count: Int, style: RadialMenuStyle) -> (size: CGSize, anchor: CGPoint) {
        let bounds = RadialMenuLayout(count: count, radius: style.radius)
            .bounds(itemDiameter: style.itemDiameter, margin: style.margin)
        return (bounds.size, CGPoint(x: -bounds.minX, y: -bounds.minY))
    }

    private var layout: RadialMenuLayout {
        RadialMenuLayout(count: items.count + 1, radius: style.radius,
                         curvature: reduceMotion ? 0 : style.curvature,
                         minimumScale: reduceMotion ? 0.6 : style.minimumScale)
    }

    private var timing: RadialMenuTiming { RadialMenuTiming(style: style, reduceMotion: reduceMotion) }

    var body: some View {
        let canvas = Self.canvas(count: items.count + 1, style: style)
        let layout = layout
        glassContainer {
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                    let index = offset + 1
                    let progress = model.progress.indices.contains(index) ? model.progress[index] : 0
                    // Yarıdan fazla yerleşmeden etkileşim yok; kapanırken de hemen kesilir.
                    let interactive = model.isExpanded && progress > 0.5
                    itemButton(item, interactive: interactive)
                        .modifier(RadialPlacement(layout: layout, index: index, progress: progress, anchor: canvas.anchor))
                        .zIndex(Double(items.count - offset))
                }
                trigger
                    .position(canvas.anchor)
                    .zIndex(Double(items.count + 1))
            }
            .frame(width: canvas.size.width, height: canvas.size.height, alignment: .topLeading)
        }
        .onAppear { model.prepare(count: items.count + 1) }
    }

    private var trigger: some View {
        Button {
            model.toggle(timing)
        } label: {
            Image(systemName: model.isExpanded ? closeIcon : triggerIcon)
                .font(.system(size: style.iconSize, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: style.itemDiameter, height: style.itemDiameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(GlassCircle(id: "trigger", namespace: glassNamespace))
        .help(model.isExpanded ? closeTitle : triggerTitle)
        .accessibilityLabel(model.isExpanded ? closeTitle : triggerTitle)
    }

    private func itemButton(_ item: RadialMenuItem, interactive: Bool) -> some View {
        Button {
            // Sheet açan öğe menüyü hemen kapatır: sheet menünün altında açılmasın.
            if item.closesMenu { model.reset() }
            item.action()
        } label: {
            item.icon
                .font(.system(size: style.iconSize, weight: .medium))
                .frame(width: style.itemDiameter, height: style.itemDiameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(GlassCircle(id: item.id, namespace: glassNamespace))
        .allowsHitTesting(interactive)
        // `.disabled` klavye odağını da keser; gizli öğe Tab ile seçilemez.
        .disabled(!interactive)
        .accessibilityHidden(!interactive)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.value ?? "")
    }

    @ViewBuilder
    private func glassContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: style.glassSpacing) { content() }
        } else {
            content()
        }
    }
}

/// Öğenin o anki yeri, ölçeği ve görünürlüğü. `Animatable`: ilerleme
/// animasyonla değişirken konum her karede yoldan hesaplanır (kavisli yol;
/// iki uç arasında düz geçiş değil).
private struct RadialPlacement: ViewModifier, Animatable {
    let layout: RadialMenuLayout
    let index: Int
    var progress: Double
    let anchor: CGPoint

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let point = layout.position(of: index, progress: progress)
        content
            .scaleEffect(layout.scale(progress: progress))
            .opacity(layout.opacity(progress: progress))
            .position(x: anchor.x + point.x, y: anchor.y + point.y)
    }
}

/// Dairesel cam: macOS 26'da native Liquid Glass (etkileşimli, ortak
/// namespace ile kararlı kimlik), öncesinde sade bir material.
private struct GlassCircle: ViewModifier {
    let id: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID(id, in: namespace)
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        }
    }
}

#Preview("Dairesel menü") {
    RadialMenuPreview()
        .padding(40)
}

/// Önizleme ve örnek kullanım: altı öğe (tetikleyici dahil).
private struct RadialMenuPreview: View {
    @State private var model = RadialMenuModel()

    var body: some View {
        RadialMenuView(
            model: model,
            items: ["circle.lefthalf.filled", "character.bubble", "clock.arrow.circlepath", "birthday.cake", "key.fill"]
                .enumerated().map { index, symbol in
                    RadialMenuItem(id: "\(index)", title: symbol, closesMenu: false,
                                   icon: AnyView(Image(systemName: symbol)), action: {})
                },
            style: RadialMenuStyle(),
            triggerTitle: "Settings",
            closeTitle: "Close",
            triggerIcon: "gearshape",
            closeIcon: "xmark"
        )
    }
}
