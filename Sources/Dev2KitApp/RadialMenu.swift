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
    /// Simge boyutu (önce 13; 2026-10-20'de ~%15 büyüdü). Daire çapı aynı.
    var iconSize: CGFloat = 15
    /// Görünmeyen çemberin yarıçapı. Öğeler çakışmasın diye en az
    /// `RadialMenuLayout.minimumRadius` kadar olmalı.
    var radius: CGFloat = 52
    /// Komşu öğeler arası en küçük boşluk: öğe sayısı artınca yarıçap en az
    /// bu boşluğu sağlayacak kadar büyür (`effectiveRadius`).
    var minimumGap: CGFloat = 12

    /// Kullanılan yarıçap: `radius`, öğeler sığmıyorsa büyütülmüş hali.
    func effectiveRadius(count: Int) -> CGFloat {
        max(radius, CGFloat(RadialMenuLayout.minimumRadius(count: count, itemDiameter: Double(itemDiameter), gap: Double(minimumGap))))
    }
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

    /// Klavyeyle odaklanan öğe (0 tetikleyici). Yalnızca klavye kullanılınca
    /// dolar: fareyle açan kullanıcı odak halkası görmez (focus-visible).
    private(set) var focusedIndex: Int?

    /// Odağı saat yönünde (`+1`) ya da tersine (`-1`) taşır; uçlarda döner.
    /// İlk tuşta odak, ileri için ilk öğeye, geri için sondakine gelir.
    func moveFocus(by step: Int) {
        let count = progress.count
        guard isExpanded, count > 0 else { return }
        guard let current = focusedIndex else {
            focusedIndex = step >= 0 ? min(1, count - 1) : count - 1
            return
        }
        focusedIndex = ((current + step) % count + count) % count
    }

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
        // Zaten açılıyorsa/açıksa tekrar başlatılmaz (gecikmeler sıfırlanmasın).
        guard !isExpanded else { return }
        focusedIndex = nil
        let layout = RadialMenuLayout(count: progress.count, radius: 1)
        // Kapanmakta olanlar hemen geri döner (görsel konumundan), henüz
        // başlamamış ya da tamamen kapanmış olanlar sırayla.
        let reversing = layout.openingOrder.filter { inFlight.contains($0) && targets[$0] == 0 }
        let rest = layout.openingOrder.filter { !reversing.contains($0) && targets[$0] == 0 }
        run(order: reversing, then: rest, target: 1, phase: .opening, timing: timing)
    }

    func close(_ timing: RadialMenuTiming) {
        // Kapanırken ikinci kapatma yok sayılır. Eskiden kapanış yeniden
        // başlıyor, süren animasyonların bitişi "eski" sayılıp atılıyor ve
        // menü kapanışta takılı kalıyordu (kapanırken dışarı tıklama).
        guard phase == .opening || phase == .open else { return }
        focusedIndex = nil
        let layout = RadialMenuLayout(count: progress.count, radius: 1)
        // Son açılan ilk kapanır; hiç başlamamış öğeye dokunulmaz.
        let started = layout.closingOrder.filter { targets[$0] == 1 }
        run(order: [], then: started, target: 0, phase: .closing, timing: timing)
    }

    /// Animasyonsuz, hemen kapalı (pencere kapandı, mod değişti, uygulama
    /// arka plana geçti). Bekleyen her şey iptal.
    func reset() {
        focusedIndex = nil
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
            // Bitiş her zaman kaydedilir (yalnızca hedef hâlâ buysa); kuşak
            // değişse bile: aksi halde öğe "sürüyor" sayılı kalıp menüyü
            // kapanışta/açılışta takılı bırakabilirdi.
            guard let self, self.targets[index] == target else { return }
            self.inFlight.remove(index)
            self.finishIfSettled(generation: self.generation)
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

    /// Panelin boyutu ve tetikleyicinin içindeki yeri.
    static func canvas(count: Int, style: RadialMenuStyle) -> (size: CGSize, anchor: CGPoint) {
        let bounds = RadialMenuLayout(count: count, radius: style.effectiveRadius(count: count))
            .bounds(itemDiameter: style.itemDiameter, margin: style.margin)
        return (bounds.size, CGPoint(x: -bounds.minX, y: -bounds.minY))
    }

    private var layout: RadialMenuLayout {
        RadialMenuLayout(count: items.count + 1, radius: style.effectiveRadius(count: items.count + 1),
                         curvature: reduceMotion ? 0 : style.curvature,
                         minimumScale: reduceMotion ? 0.6 : style.minimumScale)
    }

    private var timing: RadialMenuTiming { RadialMenuTiming(style: style, reduceMotion: reduceMotion) }

    var body: some View {
        let canvas = Self.canvas(count: items.count + 1, style: style)
        let layout = layout
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                let index = offset + 1
                let progress = model.progress.indices.contains(index) ? model.progress[index] : 0
                // Yarıdan fazla yerleşmeden etkileşim yok; kapanırken de hemen kesilir.
                let interactive = model.isExpanded && progress > 0.5
                itemButton(item, index: index, interactive: interactive)
                    .modifier(RadialPlacement(layout: layout, index: index, progress: progress, anchor: canvas.anchor))
                    .zIndex(Double(items.count - offset))
            }
            trigger
                .position(canvas.anchor)
                .zIndex(Double(items.count + 1))
        }
        .frame(width: canvas.size.width, height: canvas.size.height, alignment: .topLeading)
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
        .buttonStyle(RadialItemButtonStyle(isFocused: model.focusedIndex == 0))
        .help(model.isExpanded ? closeTitle : triggerTitle)
        .accessibilityLabel(model.isExpanded ? closeTitle : triggerTitle)
    }

    private func itemButton(_ item: RadialMenuItem, index: Int, interactive: Bool) -> some View {
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
        .buttonStyle(RadialItemButtonStyle(isFocused: interactive && model.focusedIndex == index))
        .allowsHitTesting(interactive)
        // `.disabled` klavye odağını da keser; gizli öğe Tab ile seçilemez.
        .disabled(!interactive)
        .accessibilityHidden(!interactive)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.value ?? "")
    }

    // Cam öğeler ortak `GlassEffectContainer`'da DEĞİL: kap camları tek
    // geçişte çizip öğeye uygulanan ölçeği ve üst katmanları camla birlikte
    // taşımıyordu; hover'da cam ile simge ayrı büyüyüp yamuk görünüyordu
    // (2026-10-20). Her öğe kendi camıyla; açılıştaki kısa sıvı bağ yok.
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

/// Menü öğesinin durumları (kullanıcı isteği, 2026-10-20):
/// - **Hover:** tek başına %10 büyür, mor kenar vurgusu (rim), yumuşak
///   derinlik gölgesi.
/// - **Basılı:** yaylanarak içeri gömülür (%94), iç gölge, hafif saydamlaşma.
/// - **Klavye odağı:** 2 pt siyah ayrım + 4.5 pt mor halka + yumuşak ışıma.
///
/// Cam da burada: ölçek camla birlikte uygulanır (yalnızca simge değil).
/// Cam etkileşimsiz (`.regular`): basma/hover tepkisi bu stilde, cam kendi
/// tepkisini eklerse iki kez büyürdü.
struct RadialItemButtonStyle: ButtonStyle {
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        RadialItemChrome(configuration: configuration, isFocused: isFocused)
    }
}

private struct RadialItemChrome: View {
    let configuration: ButtonStyleConfiguration
    let isFocused: Bool

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var isPressed: Bool { configuration.isPressed }

    private var scale: CGFloat {
        if isPressed { return 0.94 }
        return isHovered ? 1.1 : 1
    }

    var body: some View {
        configuration.label
            // Kenar vurgusu ve iç gölge camın İÇİNDE (simgeyle aynı katman):
            // camın üstüne bindirilen katman camın altında kalıp görünmüyordu
            // (kullanıcı geri bildirimi, 2026-10-20).
            // Basılıyken iç gölge: kenardan içe doğru koyulaşır, "gömülme".
            .background {
                Circle()
                    .fill(Color.white.opacity(0.001).shadow(.inner(color: .black.opacity(0.45), radius: 3, y: 1.5)))
                    .opacity(isPressed ? 1 : 0)
            }
            // Hover: mor kenar vurgusu (gfPurple = Theme.purple).
            .overlay {
                Circle()
                    .strokeBorder(Theme.purple.opacity(isHovered && !isPressed ? 0.95 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .modifier(GlassCircle())
            .overlay { focusRing }
            .opacity(isPressed ? 0.85 : 1)
            .scaleEffect(scale)
            .shadow(color: .black.opacity(isHovered && !isPressed ? (colorScheme == .dark ? 0.5 : 0.25) : 0),
                    radius: 8, y: 4)
            // Taktil yaylanma; Reduce Motion'da kısa ve düz.
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.26, dampingFraction: 0.55), value: isPressed)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.75), value: isHovered)
            .onHover { isHovered = $0 }
    }

    /// Yüksek kontrastlı odak halkası: önce 2 pt siyah ayrım, dışında 4.5 pt
    /// mor halka, en dışta yumuşak mor ışıma.
    @ViewBuilder
    private var focusRing: some View {
        if isFocused {
            ZStack {
                Circle().stroke(Color.black, lineWidth: 2).padding(-1)
                Circle().stroke(Theme.purple, lineWidth: 4.5).padding(-(2 + 2.25))
            }
            .shadow(color: Theme.purple.opacity(0.55), radius: 8)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// Dairesel cam: macOS 26'da native Liquid Glass, öncesinde sade material.
private struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .circle)
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
