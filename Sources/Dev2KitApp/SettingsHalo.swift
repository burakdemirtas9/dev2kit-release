import SwiftUI

/// Kapalı Ayarlar düğmesinin hemen dışındaki seyrek ışık: karşılıklı iki
/// kısa yay, sabit hızla saat yönünde döner. Düğmeyi fark ettirmek için;
/// yükleniyor göstergesi gibi okunmasın diye yanıp sönme ya da nabız yok.
struct SettingsHaloStyle {
    /// Düğme kenarından uzaklık (pt).
    var distance: CGFloat = 3
    var lineWidth: CGFloat = 1.5
    /// Her yayın uzunluğu (derece). Çevrenin büyük kısmı boş kalır.
    var arcDegrees: Double = 22
    /// Işık yoğunluğu (0–1) ve parıltının yarıçapı.
    var intensity: Double = 0.85
    var glowRadius: CGFloat = 2.5
    var glowOpacity: Double = 0.35
    /// Bir tam tur (sn).
    var period: Double = 24
    /// Görünür/gizli geçişi (150–200 ms).
    var fade: Double = 0.18

    /// Halenin düğmenin dışına taşan payı (çerçeve için). Parıltı bu
    /// çerçeveden taşabilir: araç çubuğu öğesi büyüyüp çubuğu yükseltmesin.
    var extent: CGFloat { distance + lineWidth }
}

struct SettingsHalo: View {
    /// Yalnızca menü tamamen kapalıyken `true`.
    let isVisible: Bool
    let buttonDiameter: CGFloat
    var style = SettingsHaloStyle()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Pencere anahtar değilse ya da uygulama arka plandaysa `.inactive`.
    @Environment(\.controlActiveState) private var activeState

    /// Dönüş birikimi: duraklayıp devam edince yaylar sıçramasın.
    @State private var elapsed: TimeInterval = 0
    @State private var runningSince: Date?

    private var isRunning: Bool { isVisible && !reduceMotion && activeState != .inactive }

    var body: some View {
        // Durunca zaman çizelgesi de durur: sürekli çalışan zamanlayıcı yok.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isRunning)) { context in
            arcs(rotation: rotation(at: context.date))
        }
        .frame(width: diameter, height: diameter)
        .opacity(isVisible ? 1 : 0)
        .animation(.easeOut(duration: style.fade), value: isVisible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: isRunning, initial: true) { _, running in
            if running {
                runningSince = Date()
            } else if let since = runningSince {
                elapsed += Date().timeIntervalSince(since)
                runningSince = nil
            }
        }
    }

    private var diameter: CGFloat { buttonDiameter + 2 * (style.distance + style.lineWidth / 2) }

    private func rotation(at date: Date) -> Angle {
        // Reduce Motion: dönüş yok, sabit hafif vurgu.
        guard !reduceMotion else { return .degrees(-45) }
        let total = elapsed + (runningSince.map { date.timeIntervalSince($0) } ?? 0)
        return .degrees(total.truncatingRemainder(dividingBy: style.period) / style.period * 360)
    }

    private func arcs(rotation: Angle) -> some View {
        let intensity = reduceMotion ? style.intensity * 0.6 : style.intensity
        return ZStack {
            arc(color: Theme.purple, intensity: intensity)
            arc(color: Theme.warning, intensity: intensity)
                .rotationEffect(.degrees(180))
        }
        .rotationEffect(rotation)
    }

    /// Uçları sönen ince bir iz ve altında düşük yoğunluklu, bulanık parıltı.
    private func arc(color: Color, intensity: Double) -> some View {
        let fraction = style.arcDegrees / 360
        let gradient = AngularGradient(
            stops: [
                .init(color: color.opacity(0), location: 0),
                .init(color: color.opacity(intensity), location: fraction * 0.55),
                .init(color: color.opacity(0), location: fraction),
            ],
            center: .center
        )
        let shape = Circle().trim(from: 0, to: fraction)
        return ZStack {
            shape
                .stroke(gradient, style: StrokeStyle(lineWidth: style.lineWidth * 2.5, lineCap: .round))
                .blur(radius: style.glowRadius)
                .opacity(style.glowOpacity)
            shape
                .stroke(gradient, style: StrokeStyle(lineWidth: style.lineWidth, lineCap: .round))
        }
    }
}
