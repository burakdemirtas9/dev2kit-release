import SwiftUI
import Dev2KitCore

/// İstek ve yanıtın tel üzerindeki boyutu, başlık/gövde ayrımıyla.
///
/// Neden ayrım gerekli: "666 B" gövdenin boyutu değil. 254 byte'lık bir isteğin
/// 251'i başlıksa sorun gövdede değil, taşınan başlıklardadır (çerez yığını,
/// uzun token'lar) — gateway arkasında sık sorulan soru.
struct ResponseSizePopover: View {
    let size: TransferSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            group(
                title: "Yanıt Boyutu",
                icon: "arrow.down.circle.fill",
                tint: Theme.up,
                total: size.responseTotal,
                headers: size.responseHeaders,
                body: size.responseBody
            )

            if let ratio = size.compressionRatio {
                // Sıkıştırma kazancı: tel üzerindeki gövde vs açılmış hali.
                Text("Gövde sıkıştırılmış: \(Self.bytes(size.responseBody)) → \(Self.bytes(size.responseBodyDecoded)) · %\(Int(ratio * 100)) kazanç")
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            group(
                title: "İstek Boyutu",
                icon: "arrow.up.circle.fill",
                tint: Theme.warning,
                total: size.requestTotal,
                headers: size.requestHeaders,
                body: size.requestBody
            )
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private func group(title: String, icon: String, tint: Color, total: Int64, headers: Int64, body: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(tint)
                Spacer()
                Text(Self.bytes(total))
                    .font(.system(.headline, design: .monospaced))
            }
            row("Başlıklar", headers)
            row("Gövde", body)
        }
    }

    private func row(_ title: String, _ value: Int64) -> some View {
        HStack {
            Text(title)
                .font(.secondaryText)
                .foregroundStyle(.secondary)
            Spacer()
            Text(Self.bytes(value))
                .font(.secondaryMono)
                .foregroundStyle(.secondary)
        }
    }

    /// `allowsNonnumericFormatting` kapalı: varsayılan biçimlendirici 0 byte'ı
    /// "Zero KB" diye yazıyor, tablo içinde saçma duruyor.
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func bytes(_ count: Int64) -> String {
        formatter.string(fromByteCount: count)
    }
}
