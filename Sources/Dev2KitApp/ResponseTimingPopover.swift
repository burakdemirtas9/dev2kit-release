import SwiftUI
import Dev2KitCore

/// Sürenin nerede geçtiğini gösteren şelale.
///
/// Şeritler aynı ölçekte: her aşama işin başlangıcından ne kadar sonra
/// başladıysa oradan çizilir, genişliği süresi kadardır. Böylece "hangi aşama
/// uzun" sorusuna bakmadan cevap verilir — sayıları okumaya gerek kalmaz.
///
/// Aşama kuralları Core'da (`ResponseTiming`); burada yalnızca çizim var.
struct ResponseTimingPopover: View {
    let timing: ResponseTiming

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Yanıt Süresi", systemImage: "clock")
                    .font(.headline)
                Spacer()
                Text(Self.format(timing.total))
                    .font(.system(.headline, design: .monospaced))
            }

            VStack(spacing: 5) {
                ForEach(timing.phases) { phase in
                    row(phase)
                }
            }

            if timing.isReusedConnection {
                // DNS/TCP/TLS satırlarının yokluğu eksik ölçüm değil.
                Label("Bağlantı yeniden kullanıldı — DNS, TCP ve TLS aşamaları yaşanmadı.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
    }

    private func row(_ phase: ResponseTiming.Phase) -> some View {
        let isSlowest = timing.slowest?.kind == phase.kind
        return HStack(spacing: 8) {
            Text(Self.label(phase.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)

            GeometryReader { geometry in
                let scale = timing.total > 0 ? geometry.size.width / timing.total : 0
                // En kısa aşama da görünsün: şerit 2pt'nin altına düşmez.
                let width = max(2, phase.duration * scale)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.color(phase.kind))
                    .frame(width: width, height: 12)
                    .offset(x: min(phase.start * scale, max(0, geometry.size.width - width)))
            }
            .frame(height: 12)

            Text(Self.format(phase.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isSlowest ? .primary : .secondary)
                .fontWeight(isSlowest ? .semibold : .regular)
                .frame(width: 72, alignment: .trailing)
        }
    }

    // MARK: - Görünen adlar ve renkler

    private static func label(_ kind: ResponseTiming.Phase.Kind) -> String {
        switch kind {
        case .prepare: return "Hazırlık"
        case .dns: return "DNS"
        case .tcp: return "TCP el sıkışma"
        case .tls: return "TLS el sıkışma"
        case .request: return "İstek gönderimi"
        case .waiting: return "Bekleme (TTFB)"
        case .download: return "İndirme"
        }
    }

    /// Renkler işin cinsine göre: bağlantı kurma mavimsi, sunucunun düşündüğü
    /// süre uyarı rengi (genelde en uzun olan ve bakılması gereken o), veri
    /// aktarımı yeşil, bizim tarafımızdaki hazırlık sönük.
    private static func color(_ kind: ResponseTiming.Phase.Kind) -> Color {
        switch kind {
        case .prepare, .request: return .secondary.opacity(0.5)
        case .dns: return Theme.warning.opacity(0.7)
        case .tcp: return Theme.accent.opacity(0.6)
        case .tls: return Theme.accent
        case .waiting: return Theme.down.opacity(0.75)
        case .download: return Theme.up.opacity(0.8)
        }
    }

    /// Kısa süreler ondalıklı, uzunlar tam: 8,25 ms · 143 ms.
    static func format(_ seconds: TimeInterval) -> String {
        let ms = seconds * 1000
        if ms < 10 { return String(format: "%.2f ms", ms) }
        if ms < 100 { return String(format: "%.1f ms", ms) }
        return String(format: "%.0f ms", ms)
    }
}
