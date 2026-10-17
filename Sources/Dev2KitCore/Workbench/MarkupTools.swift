import Foundation

/// XML ve HTML araçlarının kuralları (saf, testli). Biçimlendirme
/// `MarkupFormatter`'da; burada doğrulama ve sıkıştırma.
public enum MarkupTools {
    // MARK: - XML doğrulama

    /// Foundation `XMLParser` ile tam (iyi biçimlilik) doğrulama.
    ///
    /// Dış varlıklar ÇÖZÜLMEZ (`shouldResolveExternalEntities = false`,
    /// varsayılan): yapıştırılan bir XML'in makinedeki dosyaları ya da ağı
    /// okutması (XXE) mümkün olmasın.
    public static func validateXML(_ text: String) -> WorkbenchValidation {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        let parser = XMLParser(data: Data(text.utf8))
        parser.shouldResolveExternalEntities = false
        // İLK hata delegeyle yakalanır: okuyucu hatadan sonra devam ediyor ve
        // sonunda genel bir kod (111) ile belgenin sonunu bildiriyor (ölçüldü).
        let recorder = FirstErrorRecorder()
        parser.delegate = recorder
        if parser.parse() { return .valid }
        let first = recorder.first
        let code = first?.code ?? (parser.parserError as NSError?)?.code ?? -1
        let message = "Geçersiz XML: \(xmlMessage(code))"
        let line = first?.line ?? parser.lineNumber
        let column = first?.column ?? parser.columnNumber
        guard line > 0 else { return .invalid(WorkbenchIssue(message: message)) }
        return .invalid(.at(line: line, column: max(column, 1), in: text, message: message))
    }

    private final class FirstErrorRecorder: NSObject, XMLParserDelegate {
        var first: (code: Int, line: Int, column: Int)?

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            guard first == nil else { return }
            first = ((parseError as NSError).code, parser.lineNumber, parser.columnNumber)
        }
    }

    private static func xmlMessage(_ code: Int) -> String {
        switch XMLParser.ErrorCode(rawValue: code) {
        case .tagNameMismatchError?: return "açılış ve kapanış etiketi eşleşmiyor"
        case .prematureDocumentEndError?: return "belge beklenmeden bitti ya da kökten sonra içerik var (tek kök eleman olmalı)"
        case .gtRequiredError?: return "'>' bekleniyordu"
        case .ltRequiredError?: return "'<' bekleniyordu"
        case .attributeNotStartedError?, .attributeNotFinishedError?: return "öznitelik değeri tırnak içinde olmalı"
        case .attributeRedefinedError?: return "aynı öznitelik iki kez tanımlı"
        case .entityRefAtEOFError?, .entityRefLoopError?, .undeclaredEntityError?: return "tanımsız ya da hatalı entity (&…;)"
        case .lessThanSymbolInAttributeError?: return "öznitelik değerinde '<' kaçışlanmalı (&lt;)"
        case .emptyDocumentError?: return "belge boş"
        case .nameRequiredError?: return "etiket adı bekleniyordu"
        case .commentNotFinishedError?: return "yorum (<!-- -->) kapatılmamış"
        default: return "iyi biçimli değil (kod \(code))"
        }
    }

    // MARK: - HTML etiket kontrolü

    /// Kapanışı isteğe bağlı HTML elementleri: kapatılmamaları hata değil.
    static let optionalClose: Set<String> = [
        "li", "p", "dt", "dd", "tr", "td", "th", "option", "optgroup", "thead", "tbody", "tfoot",
        "colgroup", "html", "head", "body", "rt", "rp",
    ]

    /// HTML'de pek "geçersiz" yoktur (tarayıcı her şeyi yorumlar); bulunan
    /// kapanmamış ya da eşleşmeyen etiketler bildirilir. Sonuç
    /// `.structurallyValid`: arayüz "geçerli" DEMEZ.
    public static func checkHTML(_ text: String) -> WorkbenchValidation {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        let chars = Array(text)
        var stack: [(name: String, offset: Int)] = []
        var index = 0
        func issue(_ message: String, at offset: Int) -> WorkbenchValidation {
            .invalid(.at(characterOffset: offset, in: chars, message: "HTML: \(message)"))
        }
        let scanner = CodeScanner(chars: chars)

        while index < chars.count {
            guard chars[index] == "<" else { index += 1; continue }
            let start = index
            if scanner.hasPrefix("<!--", at: index) {
                guard let end = scanner.position(of: "-->", from: index + 4) else { return issue("yorum (<!-- -->) kapatılmamış", at: start) }
                index = end + 1
                continue
            }
            if scanner.hasPrefix("<!", at: index) || scanner.hasPrefix("<?", at: index) {
                guard let end = scanner.position(of: ">", from: index + 2) else { return issue("'>' bekleniyordu", at: start) }
                index = end + 1
                continue
            }
            // Etiket adı yoksa (`a < b` metni) etiket değil.
            let isClosing = index + 1 < chars.count && chars[index + 1] == "/"
            var nameEnd = index + (isClosing ? 2 : 1)
            let nameStart = nameEnd
            while nameEnd < chars.count, chars[nameEnd].isLetter || chars[nameEnd].isNumber || chars[nameEnd] == "-" || chars[nameEnd] == ":" {
                nameEnd += 1
            }
            guard nameEnd > nameStart, chars[nameStart].isLetter else { index += 1; continue }
            let name = String(chars[nameStart..<nameEnd]).lowercased()
            guard let tagEnd = tagEnd(chars, from: nameEnd) else { return issue("<\(name) etiketi '>' ile kapatılmamış", at: start) }
            let selfClosing = chars[tagEnd - 1] == "/"
            index = tagEnd + 1

            if isClosing {
                if let position = stack.lastIndex(where: { $0.name == name }) {
                    // Aradaki kapanışı isteğe bağlı olanlar örtük kapanır.
                    if let blocker = stack[(position + 1)...].last(where: { !optionalClose.contains($0.name) }) {
                        return issue("<\(blocker.name)> kapatılmadan </\(name)> geldi", at: start)
                    }
                    stack.removeSubrange(position...)
                } else if !MarkupFormatter.voidElements.contains(name) {
                    return issue("</\(name)> için açılış etiketi yok", at: start)
                }
                continue
            }
            if let closes = MarkupFormatter.closedByOpening[name] {
                while let top = stack.last, closes.contains(top.name) { stack.removeLast() }
            }
            if selfClosing || MarkupFormatter.voidElements.contains(name) { continue }
            if MarkupFormatter.rawTextElements.contains(name) || MarkupFormatter.verbatimElements.contains(name) {
                // İçerik etiket sayılmaz; kapanışa atla.
                guard let close = closingTag(chars, name: name, from: index),
                      let closeEnd = MarkupTools.tagEnd(chars, from: close) else {
                    return issue("<\(name)> kapatılmamış", at: start)
                }
                index = closeEnd + 1
                continue
            }
            stack.append((name, start))
        }
        if let unclosed = stack.last(where: { !optionalClose.contains($0.name) }) {
            return issue("<\(unclosed.name)> kapatılmamış", at: unclosed.offset)
        }
        return .structurallyValid
    }

    /// Etiketin `>` konumu; tırnak içindeki `>` sayılmaz.
    private static func tagEnd(_ chars: [Character], from start: Int) -> Int? {
        var quote: Character?
        var i = start
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
        return nil
    }

    private static func closingTag(_ chars: [Character], name: String, from start: Int) -> Int? {
        let needle = Array("</" + name)
        var i = start
        while i + needle.count <= chars.count {
            if zip(chars[i..<(i + needle.count)], needle).allSatisfy({ $0.lowercased() == $1.lowercased() }) { return i }
            i += 1
        }
        return nil
    }

    // MARK: - Sıkıştırma

    /// Yorumlar atılır. XML'de yalnızca boşluktan oluşan metin (girinti)
    /// tamamen düşer; HTML'de tek boşluğa iner — satır içi öğeler arasındaki
    /// boşluk görünümü etkiler (`<b>a</b> <i>b</i>`). CDATA, işlem talimatı,
    /// HTML'de script/style/pre/textarea içeriği olduğu gibi kalır.
    public static func minify(_ text: String, html: Bool) throws -> String {
        let language = html ? "HTML" : "XML"
        let chars = Array(try BeautifyError.requireContent(text, language: language))
        let scanner = CodeScanner(chars: chars)
        var out = ""
        var index = 0
        var textRun = ""

        func flushText() {
            defer { textRun = "" }
            guard !textRun.isEmpty else { return }
            if textRun.allSatisfy(\.isWhitespace) {
                if html { out.append(" ") }
                return
            }
            if html {
                out += textRun.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    .withEdgeSpaces(from: textRun)
            } else {
                out += textRun
            }
        }

        while index < chars.count {
            guard chars[index] == "<" else { textRun.append(chars[index]); index += 1; continue }
            if scanner.hasPrefix("<!--", at: index) {
                guard let end = scanner.position(of: "-->", from: index + 4) else {
                    throw BeautifyError.invalid(language, "yorum (<!-- -->) kapatılmamış.")
                }
                index = end + 1
                continue
            }
            if scanner.hasPrefix("<![CDATA[", at: index) {
                guard let end = scanner.position(of: "]]>", from: index + 9) else {
                    throw BeautifyError.invalid(language, "CDATA kapatılmamış.")
                }
                flushText()
                out += String(chars[index...end])
                index = end + 1
                continue
            }
            guard let end = tagEnd(chars, from: index + 1) else {
                textRun.append(chars[index]); index += 1; continue
            }
            flushText()
            let tag = String(chars[index...end])
            out += tag
            index = end + 1
            if html, !tag.hasPrefix("</") {
                let name = tag.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "-" }.lowercased()
                if MarkupFormatter.rawTextElements.contains(name) || MarkupFormatter.verbatimElements.contains(name),
                   let close = closingTag(chars, name: name, from: index) {
                    out += String(chars[index..<close])
                    index = close
                }
            }
        }
        flushText()
        return out.trimmingCharacters(in: .whitespaces)
    }
}

private extension String {
    /// Sıkıştırılmış metne asıl metnin baş/son boşluğunu tek boşluk olarak geri koyar.
    func withEdgeSpaces(from original: String) -> String {
        var result = self
        if original.first?.isWhitespace == true { result = " " + result }
        if original.last?.isWhitespace == true { result += " " }
        return result
    }
}
