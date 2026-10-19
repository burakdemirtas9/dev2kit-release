import Foundation

/// İstek gövdesindeki yorumlar yalnızca kullanıcı içindir, gönderilmez
/// (kullanıcı isteği, 2026-10-20).
///
/// Yalnızca JSON gövdede (`Content-Type`'ta `json`): JSON'da yorum geçersiz,
/// kaldırmak her zaman doğru. XML/HTML yorumu (`<!-- -->`) içeriğin parçası
/// olabilir, dokunulmaz.
///
/// Kurallar:
/// - `//` ve `/* */`; tırnak içindekiler (`"https://…"`) yorum değildir
///   (`CodeScanner.strippingComments`).
/// - Yalnızca yorumdan oluşan satır tümden düşer; satır sonu yorumunda kodun
///   sonundaki boşluk kırpılır.
/// - Yorum kaldırıldıysa `}` / `]` önünde kalan virgül de düşer: son alanı
///   yoruma almak (`// "b": 2`) aksi halde geçersiz JSON bırakırdı.
/// - Yorum yoksa metin BAYT BAYT aynı döner (eski davranış).
public enum RequestBodyComments {
    public static func appliesTo(contentType: String) -> Bool {
        contentType.lowercased().contains("json")
    }

    /// Gönderilecek (ve değişkenleri çözülecek) gövde metni.
    public static func sendable(_ content: String, contentType: String) -> String {
        guard appliesTo(contentType: contentType), content.contains("/") else { return content }
        let stripped = CodeScanner.strippingComments(content)
        guard stripped != content else { return content }

        let original = content.components(separatedBy: "\n")
        let cleaned = stripped.components(separatedBy: "\n")
        guard original.count == cleaned.count else { return stripped }
        var lines: [String] = []
        for (before, after) in zip(original, cleaned) {
            guard before != after else { lines.append(after); continue }
            let trimmed = after.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            if trimmed.isEmpty { continue }
            lines.append(trimmed)
        }
        return droppingTrailingCommas(lines.joined(separator: "\n"))
    }

    /// `}` / `]` önündeki (yalnızca boşlukla ayrılmış) virgül; tırnak içi korunur.
    static func droppingTrailingCommas(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(text.count)
        var inString = false
        var escaped = false
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            defer { index += 1 }
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                out.append(ch)
                continue
            }
            if ch == "\"" { inString = true }
            if ch == "," {
                var next = index + 1
                while next < chars.count, chars[next].isWhitespace { next += 1 }
                if next < chars.count, chars[next] == "}" || chars[next] == "]" { continue }
            }
            out.append(ch)
        }
        return out
    }
}
