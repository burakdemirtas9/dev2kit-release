import Foundation

/// JSON metnini doğrular ve girintili hale getirir.
/// JSONSerialization ile pretty-print key sırasını bozduğu için, doğrulama
/// JSONSerialization'a bırakılır ama biçimlendirme sıra koruyan bir
/// karakter tarayıcısıyla yapılır.
public enum JSONFormatter {
    public enum FormatError: Error, LocalizedError {
        case invalidJSON(String)

        public var errorDescription: String? {
            switch self {
            case .invalidJSON(let detail):
                return "Geçersiz JSON: \(detail)"
            }
        }
    }

    /// Geçerli JSON'u 2 boşluk girintiyle biçimlendirir; geçersizse hata fırlatır.
    public static func beautify(_ text: String, indent: String = "  ") throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FormatError.invalidJSON("içerik boş")
        }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
        } catch {
            let nsError = error as NSError
            let detail = (nsError.userInfo[NSDebugDescriptionErrorKey] as? String)
                ?? nsError.localizedDescription
            throw FormatError.invalidJSON(detail)
        }
        return reindent(trimmed, indent: indent)
    }

    /// Doğrulanmış JSON'u yeniden girintiler. String içeriğine dokunmaz,
    /// key/eleman sırasını korur.
    private static func reindent(_ text: String, indent: String) -> String {
        var out = ""
        var depth = 0
        var inString = false
        var escaped = false
        // Açılış parantezinden beri anlamlı karakter yazılmadıysa true;
        // boş {} / [] tek satırda kalır.
        var pendingNewline = false

        func newline() {
            out += "\n" + String(repeating: indent, count: depth)
        }

        for ch in text {
            if inString {
                out.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }
            if ch.isWhitespace { continue }
            if ch == "}" || ch == "]" {
                depth = max(0, depth - 1)
                if pendingNewline {
                    pendingNewline = false
                } else {
                    newline()
                }
                out.append(ch)
                continue
            }
            if pendingNewline {
                newline()
                pendingNewline = false
            }
            switch ch {
            case "\"":
                inString = true
                out.append(ch)
            case "{", "[":
                out.append(ch)
                depth += 1
                pendingNewline = true
            case ",":
                out.append(ch)
                newline()
            case ":":
                out += ": "
            default:
                out.append(ch)
            }
        }
        return out
    }
}
