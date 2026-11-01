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
        let parsed = parser.parse()
        if recorder.declaresEntity {
            return .invalid(WorkbenchIssue(message: L10n.t("xml.entityDeclaration")))
        }
        if parsed { return .valid }
        let first = recorder.first
        let code = first?.code ?? (parser.parserError as NSError?)?.code ?? -1
        let message = L10n.t("beautify.invalid", "XML", xmlMessage(code))
        let line = first?.line ?? parser.lineNumber
        let column = first?.column ?? parser.columnNumber
        guard line > 0 else { return .invalid(WorkbenchIssue(message: message)) }
        return .invalid(.at(line: line, column: max(column, 1), in: text, message: message))
    }

    private final class FirstErrorRecorder: NSObject, XMLParserDelegate {
        var first: (code: Int, line: Int, column: Int)?
        var declaresEntity = false

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            guard first == nil else { return }
            first = ((parseError as NSError).code, parser.lineNumber, parser.columnNumber)
        }

        /// İç varlık bildirimi görülünce durulur: libxml "billion laughs"ı
        /// kesiyor ama tek büyük varlığın binlerce kez anılmasını kesmiyor
        /// (ölçüldü: 1 MB × 20 bin anılma 9,8 sn; kesince 0,01 sn). Bildirim
        /// kökten önce gelir, genişleme başlamadan durulur.
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            declaresEntity = true
            parser.abortParsing()
        }
    }

    private static func xmlMessage(_ code: Int) -> String {
        switch XMLParser.ErrorCode(rawValue: code) {
        case .tagNameMismatchError?: return L10n.t("xml.tagMismatch")
        case .prematureDocumentEndError?: return L10n.t("xml.prematureEnd")
        case .gtRequiredError?: return "'>' bekleniyordu"
        case .ltRequiredError?: return "'<' bekleniyordu"
        case .attributeNotStartedError?, .attributeNotFinishedError?: return L10n.t("xml.attrQuote")
        case .attributeRedefinedError?: return L10n.t("xml.attrTwice")
        case .entityRefAtEOFError?, .entityRefLoopError?, .undeclaredEntityError?: return L10n.t("xml.entity")
        case .lessThanSymbolInAttributeError?: return L10n.t("xml.lessThan")
        case .emptyDocumentError?: return L10n.t("xml.empty")
        case .nameRequiredError?: return L10n.t("xml.nameRequired")
        case .commentNotFinishedError?: return L10n.t("xml.unclosedComment")
        default: return L10n.t("xml.notWellFormed", String(code))
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
                guard let end = scanner.position(of: "-->", from: index + 4) else { return issue(L10n.t("xml.unclosedComment"), at: start) }
                index = end + 1
                continue
            }
            if scanner.hasPrefix("<!", at: index) || scanner.hasPrefix("<?", at: index) {
                guard let end = scanner.position(of: ">", from: index + 2) else { return issue(L10n.t("xml.expectedGT"), at: start) }
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
            guard let tagEnd = tagEnd(chars, from: nameEnd) else { return issue(L10n.t("xml.tagNotClosed", name), at: start) }
            let selfClosing = chars[tagEnd - 1] == "/"
            index = tagEnd + 1

            if isClosing {
                if let position = stack.lastIndex(where: { $0.name == name }) {
                    // Aradaki kapanışı isteğe bağlı olanlar örtük kapanır.
                    if let blocker = stack[(position + 1)...].last(where: { !optionalClose.contains($0.name) }) {
                        return issue(L10n.t("xml.closedBefore", blocker.name, name), at: start)
                    }
                    stack.removeSubrange(position...)
                } else if !MarkupFormatter.voidElements.contains(name) {
                    return issue(L10n.t("markup.noOpen", name), at: start)
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
                    return issue(L10n.t("markup.unclosedTag", name), at: start)
                }
                index = closeEnd + 1
                continue
            }
            stack.append((name, start))
        }
        if let unclosed = stack.last(where: { !optionalClose.contains($0.name) }) {
            return issue(L10n.t("markup.unclosedTag", unclosed.name), at: unclosed.offset)
        }
        return .structurallyValid
    }

    /// Etiketin `>` konumu; tırnak içindeki `>` sayılmaz.
    /// Her başlangıç için `tagEnd`'in sonucu (yoksa -1), sağdan sola tek
    /// geçişte. `minify` kapanmamış her `<` için `tagEnd`'i baştan çağırıp
    /// metnin sonuna kadar tarıyordu: 160 KB 54 sn (yeniden inceleme,
    /// ölçüldü). Kural aynı: tırnak açan karakter eşine kadar atlanır, sonra
    /// tırnaksız devam edilir; o yüzden sonuç `ends[eş + 1]`.
    static func tagEnds(_ chars: [Character]) -> [Int] {
        var ends = [Int](repeating: -1, count: chars.count)
        var nextDouble = -1, nextSingle = -1
        for i in stride(from: chars.count - 1, through: 0, by: -1) {
            let ch = chars[i]
            let after = i + 1 < chars.count ? ends[i + 1] : -1
            switch ch {
            case ">":
                ends[i] = i
            case "\"", "'":
                let close = ch == "\"" ? nextDouble : nextSingle
                ends[i] = close == -1 || close + 1 >= chars.count ? -1 : ends[close + 1]
            default:
                ends[i] = after
            }
            if ch == "\"" { nextDouble = i }
            if ch == "'" { nextSingle = i }
        }
        return ends
    }

    static func tagEnd(_ chars: [Character], from start: Int) -> Int? {
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
        let ends = tagEnds(chars)
        // Bir konumdan bulunamayan kapanış etiketi sonrakilerden de bulunamaz:
        // `<script>` × N kapanışsız her seferinde sona kadar aranıyordu.
        var missingClose: [String: Int] = [:]
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
                    throw BeautifyError.invalid(language, L10n.t("xml.unclosedComment"))
                }
                index = end + 1
                continue
            }
            if scanner.hasPrefix("<![CDATA[", at: index) {
                guard let end = scanner.position(of: "]]>", from: index + 9) else {
                    throw BeautifyError.invalid(language, L10n.t("beautify.unclosed", "CDATA"))
                }
                flushText()
                out += String(chars[index...end])
                index = end + 1
                continue
            }
            guard index + 1 < chars.count, ends[index + 1] >= 0 else {
                textRun.append(chars[index]); index += 1; continue
            }
            let end = ends[index + 1]
            flushText()
            let tag = String(chars[index...end])
            out += tag
            index = end + 1
            if html, !tag.hasPrefix("</") {
                let name = tag.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "-" }.lowercased()
                if MarkupFormatter.rawTextElements.contains(name) || MarkupFormatter.verbatimElements.contains(name),
                   missingClose[name].map({ index < $0 }) ?? true {
                    if let close = closingTag(chars, name: name, from: index) {
                        out += String(chars[index..<close])
                        index = close
                    } else {
                        missingClose[name] = index
                    }
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
