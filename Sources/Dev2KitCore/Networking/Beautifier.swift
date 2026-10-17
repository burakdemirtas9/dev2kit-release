import Foundation

/// Metni türüne göre biçimlendiren TEK giriş noktası.
///
/// Neden var: "hangi içerik hangi biçimlendiriciyle" bilgisi üç ayrı yerde
/// tekrarlanıyordu (gövde editöründeki Beautify düğmesi, yanıt panelinin
/// görüntüleme yolu, Kibana içe aktarımı). Yeni bir tür eklendiğinde tek yer
/// değişsin diye burada toplandı.
///
/// Biçimlendiricilerin kendisi ayrı: `JSONFormatter`, `MarkupFormatter`,
/// `ScriptFormatter`. Buradaki iş yalnızca "hangisi" kararı. Hepsi aynı
/// ortak parçaları kullanır (`CodeScanner`, `IndentedWriter`, `BeautifyError`);
/// yeni bir tür eklenirken tarayıcı/yazıcı yeniden yazılmaz, bunlar kullanılır.
public enum Beautifier {
    public enum Kind: String, Sendable, CaseIterable {
        case json, xml, html, javascript, plain
    }

    /// Yalnızca başlıktan tür. Gövde tipi seçicisi gibi içeriğin henüz
    /// yazılmadığı yerlerde kullanılır; içerik varsa `kind(contentType:body:)`
    /// daha isabetli.
    public static func kind(contentType: String) -> Kind {
        kind(contentType: contentType, body: "")
    }

    /// Content-Type başlığından ve içerikten türü tahmin eder.
    ///
    /// Başlık önceliklidir; yoksa ya da tanınmıyorsa gövdeye bakılır —
    /// pek çok sunucu JSON'u `text/plain` ile gönderiyor.
    public static func kind(contentType: String, body: String) -> Kind {
        let header = contentType.lowercased()
        if header.contains("json") { return .json }
        if header.contains("xml") { return .xml }
        if header.contains("html") { return .html }
        if header.contains("javascript") { return .javascript }

        var trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Baştaki yorumu atla: `// örnek istek\n{…}` de JSON'dur.
        if trimmed.hasPrefix("/") {
            trimmed = CodeScanner.strippingComments(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return .json }
        if trimmed.hasPrefix("<") { return .xml }
        return .plain
    }

    /// Biçimlendirir. `plain` metni aynen döner — "biçimlendirilemedi" değil,
    /// "biçimlendirilecek bir şey yok" demektir.
    public static func beautify(_ text: String, as kind: Kind) throws -> String {
        switch kind {
        case .json: return try JSONFormatter.beautify(text)
        case .xml: return try MarkupFormatter.beautify(text, flavor: .xml)
        case .html: return try MarkupFormatter.beautify(text, flavor: .html)
        case .javascript: return try ScriptFormatter.beautify(text)
        case .plain: return text
        }
    }

    /// Görüntüleme yolları için: bozuk içerikte hata göstermek yerine metni
    /// olduğu gibi bırakır. Kullanıcı yanıtı yine de görebilmeli.
    public static func beautifiedOrOriginal(_ text: String, as kind: Kind) -> String {
        (try? beautify(text, as: kind)) ?? text
    }
}

public extension Beautifier.Kind {
    /// Bu tür gönderilirken kullanılacak Content-Type başlığı.
    var contentType: String {
        switch self {
        case .json: return "application/json"
        case .xml: return "application/xml"
        case .html: return "text/html"
        case .javascript: return "application/javascript"
        case .plain: return "text/plain"
        }
    }
}
