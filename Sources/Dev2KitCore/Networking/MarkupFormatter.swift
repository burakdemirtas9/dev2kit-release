import Foundation

/// XML ve HTML gövdelerini girintiler.
///
/// Etiket yapısını kendi tarayıcısıyla çözer; `XMLDocument` kullanılmadı çünkü
/// o, HTML'in gevşek yapısını (kapatılmayan `<li>`, void elementler) reddediyor
/// ve yorum/işlem talimatlarını yeniden yazarken kaybediyor.
///
/// Tarama ve yazım ortak parçalarla (`CodeScanner`, `IndentedWriter`,
/// `BeautifyError`); burada yalnızca etiket kuralları var.
public enum MarkupFormatter {
    public enum Flavor: Sendable {
        case xml
        case html

        var label: String {
            switch self {
            case .xml: return "XML"
            case .html: return "HTML"
            }
        }
    }

    /// HTML'de kapanışı olmayan elementler; derinliği artırmazlar.
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    /// HTML'de bir etiket AÇILINCA örtük olarak kapanan kardeşleri.
    ///
    /// `<li>bir<li>iki` geçerli HTML'dir: ikinci `<li>` birinciyi kapatır.
    /// Bu tablo olmadan ikinci madde birincinin İÇİNE girintileniyordu.
    ///
    /// Sınır: `<p>`nin bir blok element (`<div>`, `<table>`…) açılınca da
    /// kapandığı kural burada YOK — tam HTML ayrıştırma modeli gerektirir ve
    /// girintiden başka bir şeyi etkilemez.
    static let closedByOpening: [String: Set<String>] = [
        "li": ["li"],
        "p": ["p"],
        "dt": ["dt", "dd"],
        "dd": ["dt", "dd"],
        "tr": ["tr", "td", "th"],
        "td": ["td", "th"],
        "th": ["td", "th"],
        "option": ["option"],
        "thead": ["thead", "tbody", "tfoot"],
        "tbody": ["thead", "tbody", "tfoot"],
        "tfoot": ["thead", "tbody", "tfoot"],
    ]

    private enum Token {
        case open(raw: String, name: String)
        case close(raw: String, name: String)
        /// `<br/>`, `<?xml?>`, `<!-- -->`, `<!DOCTYPE>` — derinliği değiştirmez.
        case standalone(raw: String)
        case text(String)
        /// HTML'de `<script>`/`<style>` (yeniden girintilenir) ve `<pre>`/
        /// `<textarea>` (`verbatim`: bayt bayt korunur) içeriği. Etiket
        /// sayılmaz: script içindeki `a < b` etiket sanılıp kod bozuluyordu,
        /// `<pre>` içindeki boşluklar yeniden girintilenip içerik değişiyordu.
        case rawText(String, verbatim: Bool)
    }

    /// İçeriği etiket olarak taranmayan HTML elementleri.
    static let rawTextElements: Set<String> = ["script", "style"]
    static let verbatimElements: Set<String> = ["pre", "textarea"]

    public static func beautify(_ text: String, flavor: Flavor, indent: String = "  ") throws -> String {
        let trimmed = try BeautifyError.requireContent(text, language: flavor.label)
        let tokens = try tokenize(trimmed, flavor: flavor)
        return try render(tokens, flavor: flavor, indent: indent)
    }

    // MARK: - Tarama

    private static func tokenize(_ text: String, flavor: Flavor) throws -> [Token] {
        let chars = Array(text)
        var tokens: [Token] = []
        var index = 0

        while index < chars.count {
            if chars[index] == "<" {
                let end = try findTagEnd(chars, from: index, flavor: flavor)
                let raw = String(chars[index...end])
                let token = classify(raw)
                tokens.append(token)
                index = end + 1
                // HTML ham içerik: kapanış etiketine kadar olduğu gibi al.
                if flavor == .html, case .open(_, let name) = token {
                    let lowered = name.lowercased()
                    let verbatim = verbatimElements.contains(lowered)
                    if verbatim || rawTextElements.contains(lowered),
                       let close = closingTagStart(chars, name: lowered, from: index) {
                        if close > index {
                            tokens.append(.rawText(String(chars[index..<close]), verbatim: verbatim))
                        }
                        index = close
                    }
                }
            } else {
                var next = index
                while next < chars.count, chars[next] != "<" { next += 1 }
                let content = String(chars[index..<next])
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    tokens.append(.text(content.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                index = next
            }
        }
        return tokens
    }

    /// `</name` (büyük/küçük harf duyarsız) başlangıcı; yoksa nil.
    private static func closingTagStart(_ chars: [Character], name: String, from start: Int) -> Int? {
        let needle = Array("</" + name)
        var i = start
        while i + needle.count <= chars.count {
            if chars[i] == "<", zip(chars[i..<(i + needle.count)], needle).allSatisfy({ $0.lowercased() == $1.lowercased() }) {
                let after = i + needle.count
                if after >= chars.count || !(chars[after].isLetter || chars[after].isNumber) { return i }
            }
            i += 1
        }
        return nil
    }

    /// Etiketin kapanış `>` konumunu bulur; tırnak içindeki `>` yok sayılır.
    /// Yorum, CDATA ve işlem talimatı kendi kapanışına kadar tek parçadır:
    /// `<!-- <b> -->` içindeki etiket etiket sayılmaz.
    private static func findTagEnd(_ chars: [Character], from start: Int, flavor: Flavor) throws -> Int {
        let scanner = CodeScanner(chars: chars, index: start)
        for (open, close) in [("<!--", "-->"), ("<![CDATA[", "]]>"), ("<?", "?>")] where scanner.hasPrefix(open) {
            guard let end = scanner.position(of: close, from: start + open.count) else {
                throw BeautifyError.invalid(flavor.label, L10n.t("markup.noClose", close))
            }
            return end
        }

        var i = start + 1
        var quote: Character?
        while i < chars.count {
            let ch = chars[i]
            if let active = quote {
                if ch == active { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ">" {
                return i
            }
            i += 1
        }
        throw BeautifyError.invalid(flavor.label, L10n.t("markup.unclosedBracket"))
    }

    private static func isVerbatim(_ token: Token) -> Bool {
        if case .rawText(_, true) = token { return true }
        return false
    }

    /// Script/style içeriğinin satırları: baştaki/sondaki boş satırlar
    /// atılır, ortak girinti çıkarılır (kendi iç düzeni korunur).
    private static func dedented(_ content: String) -> [String] {
        var lines = content.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        let common = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
            .min() ?? 0
        return lines.map { String($0.dropFirst(min(common, $0.prefix { $0 == " " || $0 == "\t" }.count))) }
            .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "" : $0 }
    }

    private static func classify(_ raw: String) -> Token {
        if raw.hasPrefix("<!") || raw.hasPrefix("<?") {
            return .standalone(raw: raw)
        }
        if raw.hasSuffix("/>") {
            return .standalone(raw: raw)
        }
        if raw.hasPrefix("</") {
            return .close(raw: raw, name: tagName(raw, skip: 2))
        }
        return .open(raw: raw, name: tagName(raw, skip: 1))
    }

    private static func tagName(_ raw: String, skip: Int) -> String {
        var name = ""
        for ch in raw.dropFirst(skip) {
            if ch.isLetter || ch.isNumber || ch == ":" || ch == "-" || ch == "_" || ch == "." {
                name.append(ch)
            } else {
                break
            }
        }
        return name
    }

    // MARK: - Yazım

    private static func render(_ tokens: [Token], flavor: Flavor, indent: String) throws -> String {
        var writer = IndentedWriter(indent: indent)
        var stack: [String] = []
        var index = 0

        func emit(_ text: String) {
            writer.level = stack.count
            writer.newline()
            writer.append(text)
        }

        while index < tokens.count {
            switch tokens[index] {
            case .standalone(let raw):
                emit(raw)
                index += 1

            case .text(let content):
                emit(content)
                index += 1

            case .rawText(let content, let verbatim):
                if verbatim {
                    // Önceki satıra (açılış etiketine) yapıştır: içerik olduğu gibi.
                    writer.append(content)
                } else {
                    for line in dedented(content) { emit(line) }
                }
                index += 1

            case .open(let raw, let name) where index + 1 < tokens.count && isVerbatim(tokens[index + 1]):
                // `<pre>içerik</pre>`: açılış, içerik ve kapanış arasına
                // satır sonu ya da girinti girmez.
                if flavor == .html, let closes = closedByOpening[name.lowercased()] {
                    while let top = stack.last, closes.contains(top.lowercased()) { stack.removeLast() }
                }
                emit(raw)
                if case .rawText(let content, _) = tokens[index + 1] { writer.append(content) }
                index += 2
                if index < tokens.count, case .close(let closeRaw, let closeName) = tokens[index],
                   closeName.lowercased() == name.lowercased() {
                    writer.append(closeRaw)
                    index += 1
                } else {
                    stack.append(name)
                }

            case .open(let raw, let name):
                // Örtük kapanış: <li> açılınca açık duran <li> kapanmış sayılır.
                if flavor == .html, let closes = closedByOpening[name.lowercased()] {
                    while let top = stack.last, closes.contains(top.lowercased()) {
                        stack.removeLast()
                    }
                }
                // HTML'de void elementler kapanmaz: derinliği artırma.
                if flavor == .html, voidElements.contains(name.lowercased()) {
                    emit(raw)
                    index += 1
                    continue
                }
                // <etiket>kısa metin</etiket> → tek satırda tut.
                if index + 2 < tokens.count,
                   case .text(let content) = tokens[index + 1],
                   case .close(_, let closeName) = tokens[index + 2],
                   closeName == name,
                   !content.contains("\n") {
                    emit("\(raw)\(content)</\(name)>")
                    index += 3
                    continue
                }
                // <etiket></etiket> → tek satır.
                if index + 1 < tokens.count,
                   case .close(_, let closeName) = tokens[index + 1],
                   closeName == name {
                    emit("\(raw)</\(name)>")
                    index += 2
                    continue
                }
                emit(raw)
                stack.append(name)
                index += 1

            case .close(let raw, let name):
                guard let top = stack.last else {
                    if flavor == .html {
                        // Başıboş kapanış: HTML'de yok say.
                        index += 1
                        continue
                    }
                    throw BeautifyError.invalid(flavor.label, L10n.t("markup.noOpen", name))
                }
                if top == name {
                    stack.removeLast()
                    emit(raw)
                } else if flavor == .html, let depth = stack.lastIndex(of: name) {
                    // <li> gibi örtük kapanışlar: hedef etikete kadar yığını boşalt.
                    stack.removeSubrange(depth..<stack.count)
                    emit(raw)
                } else if flavor == .html {
                    index += 1
                    continue
                } else {
                    throw BeautifyError.invalid(
                        flavor.label,
                        L10n.t("markup.unexpectedClose", name, top)
                    )
                }
                index += 1
            }
        }

        if let unclosed = stack.last, flavor == .xml {
            throw BeautifyError.invalid(flavor.label, L10n.t("markup.unclosedTag", unclosed))
        }
        return writer.text
    }
}
