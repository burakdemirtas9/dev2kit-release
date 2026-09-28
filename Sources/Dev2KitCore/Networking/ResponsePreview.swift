import Foundation

/// Yanıtın ham hali yerine "gerçekte nasıl göründüğü" gösterilebilir mi.
///
/// Neden Core'da: "bu yanıt önizlenebilir mi, hangi türde" bir karardır ve
/// içerik türü başlığıyla gövdenin ilk byte'larına bakar. Arayüz yalnızca
/// çizer.
public enum ResponsePreview {
    public enum Kind: String, Equatable, Sendable {
        case html
        case image
        case pdf
    }

    /// Önizlemenin üst sınırı.
    ///
    /// Önizleme ham gövdeyi bir görüntüleyiciye (WebKit, PDFKit) veriyor;
    /// oradaki maliyet bizim denetimimizde değil. 8 MB'lık bir HTML'i
    /// render etmenin kullanıcıya faydası yok, arayüzü kilitleme riski var.
    public static let sizeLimit = 5 * 1024 * 1024

    public static func isWithinLimit(_ body: Data) -> Bool {
        body.count <= sizeLimit
    }

    /// Önizleme türü; önizlenemiyorsa `nil`.
    ///
    /// SVG bilinçli olarak DIŞARIDA: `image/svg+xml` bir XML belgesidir,
    /// script ve dış kaynak referansı taşıyabilir. Metin olarak (renklendirilmiş
    /// markup) göstermek hem daha güvenli hem de daha bilgilendirici.
    public static func kind(contentType: String, body: Data) -> Kind? {
        guard !body.isEmpty else { return nil }
        let header = contentType.lowercased()

        if header.contains("svg") { return nil }
        if header.contains("html") { return .html }
        if header.contains("pdf") { return .pdf }
        if header.hasPrefix("image/") { return .image }
        // Başlık bir şey söylemiyorsa (ör. application/octet-stream) gövdeye bak.
        guard header.isEmpty
            || header.contains("octet-stream")
            || header.hasPrefix("text/plain")
        else { return nil }
        return sniff(body)
    }

    // MARK: - Gövdeden tanıma

    private static let signatures: [(bytes: [UInt8], kind: Kind)] = [
        ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], .image),   // PNG
        ([0xFF, 0xD8, 0xFF], .image),                                  // JPEG
        ([0x47, 0x49, 0x46, 0x38], .image),                            // GIF8
        ([0x25, 0x50, 0x44, 0x46, 0x2D], .pdf),                        // %PDF-
    ]

    private static func sniff(_ body: Data) -> Kind? {
        let prefix = [UInt8](body.prefix(16))
        for signature in signatures where prefix.starts(with: signature.bytes) {
            return signature.kind
        }
        // RIFF....WEBP
        if prefix.count >= 12,
           Array(prefix[0..<4]) == Array("RIFF".utf8),
           Array(prefix[8..<12]) == Array("WEBP".utf8) {
            return .image
        }
        // Sunucuların bir kısmı HTML'i text/plain ile gönderiyor.
        let start = String(decoding: body.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if start.hasPrefix("<!doctype html") || start.hasPrefix("<html") {
            return .html
        }
        return nil
    }
}
