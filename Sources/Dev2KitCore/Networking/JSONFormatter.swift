import Foundation

/// JSON metnini doğrular ve girintili hale getirir.
/// JSONSerialization ile pretty-print key sırasını bozduğu için, doğrulama
/// JSONSerialization'a bırakılır ama biçimlendirme sıra koruyan bir
/// karakter tarayıcısıyla yapılır.
///
/// Yorumlar (`//`, `/* */`, JSONC) kabul edilir ve yerinde korunur: Postman
/// gövdeleri ve yapılandırma örnekleri sık sık yorum içeriyor; normal
/// beautifier'lar bunları biçimlendirir, hata vermez. Doğrulama yorumlar
/// ayıklanmış metin üzerinde yapılır.
public enum JSONFormatter {
    static let language = "JSON"

    /// Geçerli JSON'u 2 boşluk girintiyle biçimlendirir; geçersizse hata fırlatır.
    public static func beautify(_ text: String, indent: String = "  ") throws -> String {
        let trimmed = try BeautifyError.requireContent(text, language: language)
        let withoutComments = CodeScanner.strippingComments(trimmed)
        guard !withoutComments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BeautifyError.invalid(language, L10n.t("beautify.onlyComments"))
        }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(withoutComments.utf8), options: [.fragmentsAllowed])
        } catch {
            let nsError = error as NSError
            let detail = (nsError.userInfo[NSDebugDescriptionErrorKey] as? String)
                ?? nsError.localizedDescription
            throw BeautifyError.invalid(language, detail)
        }
        return try reindent(trimmed, indent: indent)
    }

    /// Doğrulanmış JSON'u yeniden girintiler. String içeriğine dokunmaz,
    /// key/eleman sırasını ve yorumları korur.
    private static func reindent(_ text: String, indent: String) throws -> String {
        var scanner = CodeScanner(text)
        var writer = IndentedWriter(indent: indent)
        // Açılış parantezinden beri anlamlı karakter yazılmadıysa true;
        // boş {} / [] tek satırda kalır.
        var pendingNewline = false

        while !scanner.isAtEnd {
            let ch = scanner.current
            if ch.isWhitespace {
                scanner.index += 1
                continue
            }
            if let comment = try scanner.readComment(language: language) {
                if pendingNewline, !comment.isTrailing {
                    writer.newline()
                    pendingNewline = false
                }
                writer.comment(comment)
                continue
            }
            if ch == "}" || ch == "]" {
                writer.level = max(0, writer.level - 1)
                if pendingNewline {
                    pendingNewline = false
                } else {
                    writer.newline()
                }
                writer.append(String(ch))
                scanner.index += 1
                continue
            }
            if pendingNewline {
                writer.newline()
                pendingNewline = false
            }
            switch ch {
            case "\"":
                // Doğrulamadan geçti: string kapalı. Yine de savunmacı.
                guard let quoted = scanner.readQuoted(multiline: false) else {
                    throw BeautifyError.invalid(language, L10n.t("beautify.unclosedString"))
                }
                writer.append(quoted)
                continue
            case "{", "[":
                writer.append(String(ch))
                writer.level += 1
                pendingNewline = true
            case ",":
                writer.append(",")
                writer.newline()
            case ":":
                writer.append(": ")
            default:
                writer.append(String(ch))
            }
            scanner.index += 1
        }
        return writer.text
    }
}
