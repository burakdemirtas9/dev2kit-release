import Foundation

/// Base64 (standart ve URL-safe). Çözerken ikisi de, dolgulu/dolgusuz ve
/// boşluk/satır sonu içeren metin kabul edilir: JWT parçası, PEM gövdesi,
/// log satırı aynı yoldan açılır.
public enum Base64Codec {
    public static func encode(_ data: Data, urlSafe: Bool) -> String {
        let standard = data.base64EncodedString()
        guard urlSafe else { return standard }
        // URL-safe (RFC 4648 §5): + → -, / → _, dolgu yok (JWT ile aynı).
        return standard.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        var base64 = String(text.filter { !$0.isWhitespace })
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        guard remainder != 1 else { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

/// Hex (onaltılık). Çözerken boşluk, `:`, `-` ve `0x` önekleri atılır.
public enum HexCodec {
    public static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func decode(_ text: String) throws -> Data {
        let cleaned = text.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "0X", with: "")
            .filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        guard cleaned.count % 2 == 0 else {
            throw WorkbenchIssue(message: "Hex çift sayıda karakter olmalı (\(cleaned.count) karakter var)")
        }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else {
                throw WorkbenchIssue(message: "Geçersiz hex: \"\(cleaned[index..<next])\"")
            }
            data.append(byte)
            index = next
        }
        return data
    }
}

/// URL yüzde kodlaması (bir parça/değer için). "Form" modunda boşluk `+`
/// (application/x-www-form-urlencoded, HTML formları ve çoğu sorgu değeri).
public enum URLCodec {
    /// RFC 3986 ayrılmamış karakterler dışındaki her şey kodlanır.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func encode(_ text: String, form: Bool) -> String {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
        return form ? encoded.replacingOccurrences(of: "%20", with: "+") : encoded
    }

    public static func decode(_ text: String, form: Bool) throws -> String {
        let source = form ? text.replacingOccurrences(of: "+", with: " ") : text
        guard let decoded = source.removingPercentEncoding else {
            throw WorkbenchIssue(message: "Geçersiz yüzde kodlaması: % ardından iki hex basamak olmalı (ör. %20)")
        }
        return decoded
    }
}

/// Çözülmüş baytların metni: UTF-8 değilse açıklama + hex (veri kaybolmasın).
enum DecodedText {
    static func text(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        let preview = HexCodec.encode(data.prefix(4_096))
        return "// Binary data (\(data.count) bytes), not UTF-8 text. Hex:\n" + preview + (data.count > 4_096 ? "…" : "")
    }
}
