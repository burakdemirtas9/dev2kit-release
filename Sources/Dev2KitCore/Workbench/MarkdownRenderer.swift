import Foundation

/// Markdown → HTML (Workbench "Markdown Viewer", v2 step 4; 2026-11-01).
///
/// Bağımlılıksız; CommonMark'ın günlük kullanılan kısmı ve GitHub eklentileri:
/// başlık (ATX ve altı çizili), paragraf, satır sonu, alıntı, liste (sıralı,
/// sırasız, iç içe, görev kutusu), çit ve girintili kod bloğu, tablo
/// (hizalamalı), yatay çizgi, vurgu (`*`, `_`, `**`, `~~`), satır içi kod,
/// bağlantı ve görsel (satır içi ve referans), `<adres>` ve çıplak
/// `https://` / `www.` bağlantıları, HTML varlıkları.
///
/// **Ham HTML olduğu gibi geçer** (kullanıcı kararı, 2026-11-01; CommonMark ve
/// IntelliJ böyle): README'lerdeki `<img>`, `<details>`, `<br>` çalışsın.
/// Güvenlik görüntüleyicinin kendisinden gelir (`IsolatedWeb`: script kapalı,
/// dış kaynak yüklenmez, gezinme yok). Yine de bağlantı ve görsel adreslerinde
/// `javascript:`, `vbscript:`, `file:` ve görsel olmayan `data:` düşer:
/// "HTML" eyleminin çıktısı kopyalanıp başka yerde kullanılabilir.
///
/// Bozuk ya da kötü niyetli girdi (binlerce `[`, `<`, `` ` ``, `*`, iç içe
/// `>`) kare büyümeye yol açmasın diye: satır içi taramalar `scanLimit` ile
/// sınırlı, vurgu eşleştirme bağlı liste üzerinde, iç içe blok derinliği
/// `maxNesting` ile sınırlı (aşan kısım düz metin).
public enum MarkdownRenderer {
    /// İç içe blok (alıntı, liste) derinliği; aşan kısım paragraf olarak çizilir.
    public static let maxNesting = 32
    /// Tek bir satır içi yapının (etiket, bağlantı adresi, yorum) en uzun hali.
    static let scanLimit = 4_096

    /// Gövde parçası (`<h1>…</h1>\n<p>…</p>`): "HTML" eyleminin çıktısı.
    public static func html(_ markdown: String) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0}", with: "\u{FFFD}")
        let parser = BlockParser()
        let blocks = parser.parse(normalized.components(separatedBy: "\n"), depth: 0)
        var out = ""
        BlockWriter(definitions: parser.definitions).write(blocks, tight: false, into: &out)
        return out
    }

    /// Önizlemede gösterilen tam belge: gövde + açık/koyu temaya uyan stil.
    /// Renkler sistem renkleri (`Canvas`, `CanvasText`, `LinkText`), onların
    /// karışımı ve yarı saydam gri: sabit renk yok, sayfa uygulamanın temasını
    /// izler. (`GrayText` alıntıda açık temada okunmayacak kadar soluktu.)
    public static func document(_ markdown: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <style>\(style)</style></head>
        <body>
        \(html(markdown))</body></html>
        """
    }

    static let style = """
    :root{color-scheme:light dark}
    html{background:Canvas}
    body{margin:0;padding:16px 24px 32px;font:14px/1.6 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;color:CanvasText;overflow-wrap:break-word}
    body>:first-child{margin-top:0}
    h1,h2,h3,h4,h5,h6{margin:24px 0 12px;font-weight:600;line-height:1.25}
    h1{font-size:2em}h2{font-size:1.5em}h3{font-size:1.25em}h4{font-size:1em}h5{font-size:.875em}h6{font-size:.85em;color:color-mix(in srgb,CanvasText 65%,transparent)}
    h1,h2{padding-bottom:.3em;border-bottom:1px solid rgba(128,128,128,.3)}
    p,ul,ol,blockquote,pre,table,details{margin:0 0 16px}
    a{color:-webkit-link;color:LinkText;text-decoration:none}
    a:hover{text-decoration:underline}
    code,pre{font-family:ui-monospace,"SF Mono",Menlo,monospace;font-size:85%}
    code{padding:.2em .4em;border-radius:6px;background:rgba(128,128,128,.15)}
    pre{padding:12px 16px;overflow:auto;border-radius:6px;background:rgba(128,128,128,.12);line-height:1.45}
    pre code{padding:0;background:none;font-size:100%}
    blockquote{margin-left:0;padding:0 1em;color:color-mix(in srgb,CanvasText 65%,transparent);border-left:.25em solid rgba(128,128,128,.4)}
    ul,ol{padding-left:2em}
    li+li{margin-top:.25em}
    li>p{margin:0 0 8px}
    li.task{list-style:none}
    li.task>input{margin:0 .4em 0 -1.4em;vertical-align:middle}
    table{border-collapse:collapse;display:block;width:max-content;max-width:100%;overflow:auto}
    th,td{padding:6px 13px;border:1px solid rgba(128,128,128,.35)}
    th{font-weight:600}
    tr:nth-child(2n){background:rgba(128,128,128,.06)}
    hr{height:.25em;margin:24px 0;border:0;background:rgba(128,128,128,.3)}
    img{max-width:100%}
    """
}

// MARK: - Bloklar

extension MarkdownRenderer {
    struct LinkDefinition {
        let url: String
        let title: String?
    }

    enum Alignment: String {
        case left, center, right
    }

    indirect enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case code(text: String, language: String)
        case html(String)
        case quote([Block])
        case list(ordered: Bool, start: Int, tight: Bool, items: [ListItem])
        case table(header: [String], alignments: [Alignment?], rows: [[String]])
        case rule
    }

    struct ListItem {
        /// `nil`: görev değil; `true`/`false`: işaretli/boş kutu.
        let task: Bool?
        let blocks: [Block]
    }

    struct ListMarker {
        let ordered: Bool
        let symbol: Character
        let start: Int
        /// Satır başından içeriğe kadar sütun.
        let contentIndent: Int
        let content: String
        var isEmpty: Bool { content.allSatisfy { $0 == " " || $0 == "\t" } }

        func continues(_ other: ListMarker) -> Bool {
            ordered == other.ordered && symbol == other.symbol
        }
    }

    enum HTMLBlockEnd {
        /// `<script>`, `<pre>`, `<style>`, `<textarea>`: kapanış etiketine kadar.
        case tag(String)
        case comment
        case blankLine
    }

    final class BlockParser {
        var definitions: [String: LinkDefinition] = [:]

        func parse(_ lines: [String], depth: Int) -> [Block] {
            if depth > MarkdownRenderer.maxNesting {
                let text = lines.map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? [] : [.paragraph(text)]
            }
            var blocks: [Block] = []
            var i = 0
            while i < lines.count {
                let line = lines[i]
                if Line.isBlank(line) { i += 1; continue }
                let indent = Line.leading(line).columns

                if indent >= 4 {
                    var code: [String] = []
                    while i < lines.count, Line.isBlank(lines[i]) || Line.leading(lines[i]).columns >= 4 {
                        code.append(Line.dropColumns(lines[i], 4))
                        i += 1
                    }
                    while let last = code.last, Line.isBlank(last) { code.removeLast() }
                    blocks.append(.code(text: code.joined(separator: "\n"), language: ""))
                    continue
                }
                if let fence = Line.fence(line) {
                    i += 1
                    var code: [String] = []
                    while i < lines.count {
                        if Line.closesFence(lines[i], fence) { i += 1; break }
                        code.append(Line.dropColumns(lines[i], fence.indent))
                        i += 1
                    }
                    blocks.append(.code(text: code.joined(separator: "\n"), language: fence.language))
                    continue
                }
                if let heading = Line.atxHeading(line) {
                    blocks.append(.heading(level: heading.level, text: heading.text))
                    i += 1
                    continue
                }
                if Line.isRule(line) {
                    blocks.append(.rule)
                    i += 1
                    continue
                }
                if Line.quoteContent(line) != nil {
                    blocks.append(.quote(parse(collectQuote(lines, &i), depth: depth + 1)))
                    continue
                }
                if let end = Line.htmlBlockStart(line, interruptingParagraph: false) {
                    blocks.append(.html(collectHTML(lines, &i, end: end)))
                    continue
                }
                if let marker = Line.listMarker(line) {
                    blocks.append(parseList(lines, &i, first: marker, depth: depth))
                    continue
                }
                if let table = Line.table(lines, at: i) {
                    blocks.append(collectTable(lines, &i, header: table.header, alignments: table.alignments))
                    continue
                }
                if let block = parseParagraph(lines, &i) { blocks.append(block) }
            }
            return blocks
        }

        /// Paragraf; altı çizili başlık ve satır başındaki referans tanımları dahil.
        private func parseParagraph(_ lines: [String], _ i: inout Int) -> Block? {
            var text = [Line.trimmedLeading(lines[i])]
            i += 1
            while i < lines.count {
                let line = lines[i]
                if Line.isBlank(line) { break }
                if Line.leading(line).columns < 4 {
                    if let level = Line.setextLevel(line) {
                        i += 1
                        let content = consumeDefinitions(text)
                        if content.isEmpty { return .paragraph(Line.trimmedLeading(line)) }
                        return .heading(level: level, text: content.joined(separator: "\n").trimmingCharacters(in: .whitespaces))
                    }
                    if Line.interruptsParagraph(line) || Line.table(lines, at: i) != nil { break }
                }
                text.append(Line.trimmedLeading(line))
                i += 1
            }
            let content = consumeDefinitions(text)
            guard !content.isEmpty else { return nil }
            var joined = content.joined(separator: "\n")
            while joined.last == " " || joined.last == "\t" { joined.removeLast() }
            return .paragraph(joined)
        }

        /// `[etiket]: adres "başlık"` satırları paragrafın başından alınır.
        private func consumeDefinitions(_ lines: [String]) -> [String] {
            var index = 0
            while index < lines.count, let definition = Line.definition(lines[index]) {
                let key = Line.normalizedLabel(definition.label)
                if definitions[key] == nil {
                    definitions[key] = LinkDefinition(url: definition.url, title: definition.title)
                }
                index += 1
            }
            return Array(lines[index...])
        }

        private func collectQuote(_ lines: [String], _ i: inout Int) -> [String] {
            var inner: [String] = []
            while i < lines.count {
                if let content = Line.quoteContent(lines[i]) {
                    inner.append(content)
                    i += 1
                    continue
                }
                // Tembel devam: alıntıdaki paragrafın `>`sız sürmesi.
                if !Line.isBlank(lines[i]), let last = inner.last, !Line.isBlank(last),
                   Line.fence(last) == nil, Line.leading(last).columns < 4,
                   !Line.interruptsParagraph(lines[i]) {
                    inner.append(lines[i])
                    i += 1
                    continue
                }
                break
            }
            return inner
        }

        private func collectHTML(_ lines: [String], _ i: inout Int, end: HTMLBlockEnd) -> String {
            var html: [String] = []
            while i < lines.count {
                let line = lines[i]
                switch end {
                case .blankLine:
                    if Line.isBlank(line) { return html.joined(separator: "\n") }
                    html.append(line)
                    i += 1
                case .comment:
                    html.append(line)
                    i += 1
                    if line.contains("-->") { return html.joined(separator: "\n") }
                case .tag(let closing):
                    html.append(line)
                    i += 1
                    if line.lowercased().contains(closing) { return html.joined(separator: "\n") }
                }
            }
            return html.joined(separator: "\n")
        }

        private func collectTable(_ lines: [String], _ i: inout Int, header: [String], alignments: [Alignment?]) -> Block {
            i += 2
            var rows: [[String]] = []
            while i < lines.count, !Line.isBlank(lines[i]), !Line.interruptsParagraph(lines[i]) {
                var cells = Line.cells(lines[i])
                if cells.count < header.count {
                    cells += Array(repeating: "", count: header.count - cells.count)
                } else if cells.count > header.count {
                    cells = Array(cells.prefix(header.count))
                }
                rows.append(cells)
                i += 1
            }
            return .table(header: header, alignments: alignments, rows: rows)
        }

        private func parseList(_ lines: [String], _ i: inout Int, first: ListMarker, depth: Int) -> Block {
            var items: [ListItem] = []
            var tight = true
            var marker = first
            while true {
                var itemLines = [marker.content]
                i += 1
                // Boş başlayan madde en çok bir boş satır taşır.
                if marker.isEmpty, i < lines.count, Line.isBlank(lines[i]) {
                    itemLines = []
                } else {
                    while i < lines.count {
                        let line = lines[i]
                        if Line.isBlank(line) {
                            itemLines.append("")
                            i += 1
                            continue
                        }
                        if Line.leading(line).columns >= marker.contentIndent {
                            itemLines.append(Line.dropColumns(line, marker.contentIndent))
                            i += 1
                            continue
                        }
                        // Tembel devam: maddenin paragrafı girintisiz sürüyor.
                        if let last = itemLines.last, !Line.isBlank(last), Line.fence(last) == nil,
                           !Line.interruptsParagraph(line), Line.listMarker(line) == nil {
                            itemLines.append(Line.trimmedLeading(line))
                            i += 1
                            continue
                        }
                        break
                    }
                }
                var trailingBlanks = 0
                while let last = itemLines.last, Line.isBlank(last) {
                    itemLines.removeLast()
                    trailingBlanks += 1
                }
                if Line.hasInnerBlankLine(itemLines) { tight = false }
                let (task, content) = Line.taskPrefix(itemLines)
                items.append(ListItem(task: task, blocks: parse(content, depth: depth + 1)))

                guard i < lines.count, let next = Line.listMarker(lines[i]), next.continues(marker),
                      !Line.isRule(lines[i]) else { break }
                if trailingBlanks > 0 { tight = false }
                marker = next
            }
            return .list(ordered: first.ordered, start: first.start, tight: tight, items: items)
        }
    }
}

// MARK: - Satır kuralları

extension MarkdownRenderer {
    enum Line {
        static func isBlank<S: StringProtocol>(_ line: S) -> Bool {
            line.allSatisfy { $0 == " " || $0 == "\t" }
        }

        /// Baştaki boşluk sütunu (sekme 4'lük durağa) ve geri kalan.
        static func leading<S: StringProtocol>(_ line: S) -> (columns: Int, rest: S.SubSequence) {
            var columns = 0
            var index = line.startIndex
            while index < line.endIndex {
                let character = line[index]
                if character == " " {
                    columns += 1
                } else if character == "\t" {
                    columns += 4 - columns % 4
                } else {
                    break
                }
                index = line.index(after: index)
            }
            return (columns, line[index...])
        }

        static func trimmedLeading(_ line: String) -> String {
            String(leading(line).rest)
        }

        /// Baştan en çok `count` sütunluk boşluk atar; yarım kalan sekme boşluk olur.
        static func dropColumns(_ line: String, _ count: Int) -> String {
            var columns = 0
            var index = line.startIndex
            while index < line.endIndex, columns < count {
                let character = line[index]
                if character == " " {
                    columns += 1
                } else if character == "\t" {
                    let width = 4 - columns % 4
                    if columns + width > count {
                        let remaining = columns + width - count
                        return String(repeating: " ", count: remaining) + line[line.index(after: index)...]
                    }
                    columns += width
                } else {
                    break
                }
                index = line.index(after: index)
            }
            return String(line[index...])
        }

        struct Fence {
            let character: Character
            let length: Int
            let indent: Int
            let language: String
        }

        static func fence(_ line: String) -> Fence? {
            let (indent, rest) = leading(line)
            guard indent < 4, let first = rest.first, first == "`" || first == "~" else { return nil }
            let length = rest.prefix { $0 == first }.count
            guard length >= 3 else { return nil }
            let info = rest.dropFirst(length).trimmingCharacters(in: .whitespaces)
            if first == "`", info.contains("`") { return nil }
            let language = info.prefix { !$0.isWhitespace }
                .filter { $0.isLetter || $0.isNumber || "+-_.#".contains($0) }
            return Fence(character: first, length: length, indent: indent, language: String(language))
        }

        static func closesFence(_ line: String, _ fence: Fence) -> Bool {
            let (indent, rest) = leading(line)
            guard indent < 4 else { return false }
            let length = rest.prefix { $0 == fence.character }.count
            return length >= fence.length && isBlank(rest.dropFirst(length))
        }

        static func atxHeading(_ line: String) -> (level: Int, text: String)? {
            let (indent, rest) = leading(line)
            guard indent < 4, rest.first == "#" else { return nil }
            let level = rest.prefix { $0 == "#" }.count
            guard level <= 6 else { return nil }
            let after = rest.dropFirst(level)
            guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
            var text = after.trimmingCharacters(in: .whitespaces)
            // Kapanış `###` (önünde boşluk varsa ya da tek başınaysa) atılır.
            let closing = text.reversed().prefix { $0 == "#" }.count
            if closing > 0 {
                let remainder = text.dropLast(closing)
                if remainder.isEmpty || remainder.last == " " || remainder.last == "\t" {
                    text = remainder.trimmingCharacters(in: .whitespaces)
                }
            }
            return (level, text)
        }

        static func isRule(_ line: String) -> Bool {
            let (indent, rest) = leading(line)
            guard indent < 4, let first = rest.first, first == "*" || first == "-" || first == "_" else { return false }
            var count = 0
            for character in rest {
                if character == first {
                    count += 1
                } else if character != " " && character != "\t" {
                    return false
                }
            }
            return count >= 3
        }

        static func setextLevel(_ line: String) -> Int? {
            let (indent, rest) = leading(line)
            guard indent < 4, let first = rest.first, first == "=" || first == "-" else { return nil }
            let run = rest.prefix { $0 == first }
            guard isBlank(rest.dropFirst(run.count)) else { return nil }
            return first == "=" ? 1 : 2
        }

        static func quoteContent(_ line: String) -> String? {
            let (indent, rest) = leading(line)
            guard indent < 4, rest.first == ">" else { return nil }
            let after = rest.dropFirst()
            if after.first == " " { return String(after.dropFirst()) }
            if after.first == "\t" { return dropColumns(String(after), 1) }
            return String(after)
        }

        static func listMarker(_ line: String) -> ListMarker? {
            let (indent, rest) = leading(line)
            guard indent < 4, let first = rest.first else { return nil }
            var ordered = false
            var symbol = first
            var start = 1
            var markerLength = 1
            if first == "-" || first == "+" || first == "*" {
                // varsayılanlar
            } else if first.isASCII, first.isNumber {
                let digits = rest.prefix { $0.isASCII && $0.isNumber }
                guard digits.count <= 9 else { return nil }
                let delimiterIndex = rest.index(rest.startIndex, offsetBy: digits.count)
                guard delimiterIndex < rest.endIndex, rest[delimiterIndex] == "." || rest[delimiterIndex] == ")" else { return nil }
                ordered = true
                symbol = rest[delimiterIndex]
                start = Int(digits) ?? 1
                markerLength = digits.count + 1
            } else {
                return nil
            }
            let afterMarker = rest.dropFirst(markerLength)
            if let next = afterMarker.first, next != " ", next != "\t" { return nil }
            let (spaces, content) = leading(afterMarker)
            let isEmpty = isBlank(content)
            // 5+ boşluk: içerik girintili kod bloğu, madde içeriği bir boşluktan başlar.
            let padding = isEmpty || spaces > 4 ? 1 : spaces
            let text = isEmpty ? "" : (spaces > 4 ? String(repeating: " ", count: spaces - 1) + content : String(content))
            return ListMarker(ordered: ordered, symbol: symbol, start: start,
                              contentIndent: indent + markerLength + padding, content: text)
        }

        static let rawTags = ["script", "pre", "style", "textarea"]
        static let blockTags: Set<String> = [
            "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center",
            "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption",
            "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head",
            "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav",
            "noframes", "ol", "optgroup", "option", "p", "param", "search", "section", "summary", "table",
            "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul",
        ]

        /// HTML bloğu başlıyor mu (CommonMark tür 1, 2, 6, 7).
        static func htmlBlockStart(_ line: String, interruptingParagraph: Bool) -> HTMLBlockEnd? {
            let (indent, rest) = leading(line)
            guard indent < 4, rest.first == "<" else { return nil }
            if rest.hasPrefix("<!--") { return .comment }
            let closing = rest.dropFirst().first == "/"
            let nameStart = rest.dropFirst(closing ? 2 : 1)
            let name = nameStart.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.lowercased()
            guard !name.isEmpty else { return nil }
            let after = nameStart.dropFirst(name.count).first
            let endsName = after == nil || after == " " || after == "\t" || after == ">" || after == "/"
            if !closing, rawTags.contains(name), endsName, after != "/" {
                return .tag("</\(name)>")
            }
            if blockTags.contains(name), endsName { return .blankLine }
            // Tür 7: satırda tek başına tam bir etiket; paragrafı kesmez.
            if !interruptingParagraph {
                let characters = Array(rest)
                if let end = Inline.tagEnd(characters, at: 0), characters[end...].allSatisfy({ $0 == " " || $0 == "\t" }) {
                    return .blankLine
                }
            }
            return nil
        }

        /// Paragrafı kesip yeni blok başlatan satır.
        static func interruptsParagraph(_ line: String) -> Bool {
            if fence(line) != nil || atxHeading(line) != nil || isRule(line) || quoteContent(line) != nil {
                return true
            }
            if htmlBlockStart(line, interruptingParagraph: true) != nil { return true }
            // Liste paragrafı yalnızca boş olmayan madde ve 1'den başlayan sırayla keser.
            if let marker = listMarker(line), !marker.isEmpty, !marker.ordered || marker.start == 1 { return true }
            return false
        }

        static func table(_ lines: [String], at index: Int) -> (header: [String], alignments: [Alignment?])? {
            guard index + 1 < lines.count, lines[index].contains("|"), leading(lines[index]).columns < 4,
                  let alignments = delimiterRow(lines[index + 1]) else { return nil }
            let header = cells(lines[index])
            guard header.count == alignments.count else { return nil }
            return (header, alignments)
        }

        static func delimiterRow(_ line: String) -> [Alignment?]? {
            guard line.contains("|"), line.contains("-"), leading(line).columns < 4 else { return nil }
            var alignments: [Alignment?] = []
            for cell in cells(line) {
                let trimmed = cell.trimmingCharacters(in: .whitespaces)
                let left = trimmed.hasPrefix(":")
                let right = trimmed.hasSuffix(":") && trimmed.count > 1
                let dashes = trimmed.dropFirst(left ? 1 : 0).dropLast(right ? 1 : 0)
                guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
                alignments.append(left && right ? .center : right ? .right : left ? .left : nil)
            }
            return alignments.isEmpty ? nil : alignments
        }

        /// Tablo satırının hücreleri; `\|` hücre içinde `|` olur.
        static func cells(_ line: String) -> [String] {
            var row = Substring(line.trimmingCharacters(in: .whitespaces))
            if row.hasPrefix("|") { row = row.dropFirst() }
            if row.hasSuffix("|"), !row.hasSuffix("\\|") { row = row.dropLast() }
            var cells: [String] = []
            var current = ""
            var escaped = false
            for character in row {
                if escaped {
                    if character != "|" { current.append("\\") }
                    current.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "|" {
                    cells.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(character)
                }
            }
            if escaped { current.append("\\") }
            cells.append(current.trimmingCharacters(in: .whitespaces))
            return cells
        }

        static func definition(_ line: String) -> (label: String, url: String, title: String?)? {
            let (indent, rest) = leading(line)
            guard indent < 4, rest.first == "[",
                  let close = rest.firstIndex(of: "]"), rest.index(after: close) < rest.endIndex,
                  rest[rest.index(after: close)] == ":" else { return nil }
            let label = rest[rest.index(after: rest.startIndex)..<close]
            guard !label.trimmingCharacters(in: .whitespaces).isEmpty, label.count <= 999, !label.contains("[") else { return nil }
            var tail = rest[rest.index(close, offsetBy: 2)...].drop { $0 == " " || $0 == "\t" }
            guard !tail.isEmpty else { return nil }
            var url: Substring
            if tail.first == "<" {
                guard let end = tail.firstIndex(of: ">") else { return nil }
                url = tail[tail.index(after: tail.startIndex)..<end]
                tail = tail[tail.index(after: end)...]
            } else {
                url = tail.prefix { !$0.isWhitespace }
                tail = tail.dropFirst(url.count)
            }
            let remainder = tail.trimmingCharacters(in: .whitespaces)
            var title: String?
            if !remainder.isEmpty {
                guard tail.first == " " || tail.first == "\t", let open = remainder.first,
                      remainder.count >= 2 else { return nil }
                let close: Character = open == "(" ? ")" : open
                guard "\"'(".contains(open), remainder.last == close else { return nil }
                title = String(remainder.dropFirst().dropLast())
            }
            return (String(label), Inline.unescape(String(url)), title.map(Inline.unescape))
        }

        static func normalizedLabel(_ label: String) -> String {
            label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        }

        /// Kod çiti dışında, iki dolu satır arasında boş satır var mı (gevşek liste).
        static func hasInnerBlankLine(_ lines: [String]) -> Bool {
            var fence: Fence?
            var sawContent = false
            var pendingBlank = false
            for line in lines {
                if let open = fence {
                    if closesFence(line, open) { fence = nil }
                    continue
                }
                if isBlank(line) {
                    if sawContent { pendingBlank = true }
                    continue
                }
                if pendingBlank { return true }
                sawContent = true
                // İç içe listenin kendi boşlukları dış listeyi gevşetmesin.
                if leading(line).columns >= 2 { continue }
                fence = Line.fence(line)
            }
            return false
        }

        /// `[ ]` / `[x]` ile başlayan madde görev kutusu olur.
        static func taskPrefix(_ lines: [String]) -> (Bool?, [String]) {
            guard let first = lines.first, first.count >= 3 else { return (nil, lines) }
            let prefix = first.prefix(3)
            let checked: Bool
            switch prefix {
            case "[ ]": checked = false
            case "[x]", "[X]": checked = true
            default: return (nil, lines)
            }
            let rest = first.dropFirst(3)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return (nil, lines) }
            var result = lines
            result[0] = String(rest.drop { $0 == " " || $0 == "\t" })
            return (checked, result)
        }
    }
}

// MARK: - Yazım

extension MarkdownRenderer {
    struct BlockWriter {
        let definitions: [String: LinkDefinition]

        func write(_ blocks: [Block], tight: Bool, into out: inout String) {
            for block in blocks {
                switch block {
                case .heading(let level, let text):
                    out += "<h\(level)>\(inline(text))</h\(level)>\n"
                case .paragraph(let text):
                    out += tight ? inline(text) + "\n" : "<p>\(inline(text))</p>\n"
                case .code(let text, let language):
                    let attribute = language.isEmpty ? "" : " class=\"language-\(Inline.escape(language))\""
                    let body = text.isEmpty ? "" : Inline.escape(text) + "\n"
                    out += "<pre><code\(attribute)>\(body)</code></pre>\n"
                case .html(let html):
                    out += html + "\n"
                case .quote(let inner):
                    out += "<blockquote>\n"
                    write(inner, tight: false, into: &out)
                    out += "</blockquote>\n"
                case .list(let ordered, let start, let isTight, let items):
                    let tag = ordered ? "ol" : "ul"
                    out += ordered && start != 1 ? "<ol start=\"\(start)\">\n" : "<\(tag)>\n"
                    for item in items {
                        var body = ""
                        write(item.blocks, tight: isTight, into: &body)
                        // Sıkı maddede düz metin `<li>metin</li>`; iç blokla biten madde satır sonunu korur.
                        if isTight, body.hasSuffix("\n"), !body.hasSuffix(">\n") {
                            body.removeLast()
                        }
                        if let checked = item.task {
                            let box = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
                            out += "<li class=\"task\">\(box)\(body)</li>\n"
                        } else {
                            out += body.hasPrefix("<") && !isTight ? "<li>\n\(body)</li>\n" : "<li>\(body)</li>\n"
                        }
                    }
                    out += "</\(tag)>\n"
                case .table(let header, let alignments, let rows):
                    out += "<table>\n<thead>\n<tr>\n"
                    for (index, cell) in header.enumerated() {
                        out += "<th\(alignment(alignments[index]))>\(inline(cell))</th>\n"
                    }
                    out += "</tr>\n</thead>\n"
                    if !rows.isEmpty {
                        out += "<tbody>\n"
                        for row in rows {
                            out += "<tr>\n"
                            for (index, cell) in row.enumerated() {
                                out += "<td\(alignment(alignments[index]))>\(inline(cell))</td>\n"
                            }
                            out += "</tr>\n"
                        }
                        out += "</tbody>\n"
                    }
                    out += "</table>\n"
                case .rule:
                    out += "<hr />\n"
                }
            }
        }

        private func alignment(_ value: Alignment?) -> String {
            value.map { " style=\"text-align:\($0.rawValue)\"" } ?? ""
        }

        private func inline(_ text: String) -> String {
            Inline(text, definitions: definitions).render()
        }
    }
}

// MARK: - Satır içi

extension MarkdownRenderer {
    /// Satır içi yazım: kaçış, kod, vurgu, bağlantı, görsel, ham HTML.
    ///
    /// CommonMark'ın "ayraç yığını" yöntemi: `*`, `_`, `~` dizileri ve `[`
    /// açıkları parça olarak tutulur; eşleşince parçaların etrafına etiket
    /// eklenir. Ayraçlar bağlı listede: araya düşen ayraç sabit sürede silinir.
    final class Inline {
        private struct Piece {
            var text: String
            /// Ayraç parçasıysa ayraç kaydı (kalan sayı kadar karakter yazılır).
            var delimiter: Int?
            var opening: [String] = []
            var closing: [String] = []
        }

        private struct Delimiter {
            let piece: Int
            let character: Character
            var count: Int
            let original: Int
            let canOpen: Bool
            let canClose: Bool
            var previous: Int
            var next: Int
        }

        private struct Bracket {
            let piece: Int
            let isImage: Bool
            /// Etiket metninin kaynaktaki başlangıcı (`[`'den sonra).
            let source: Int
            let delimiterBottom: Int
        }

        private let characters: [Character]
        private let definitions: [String: LinkDefinition]
        private var pieces: [Piece] = []
        private var delimiters: [Delimiter] = []
        private var tail = -1
        private var brackets: [Bracket] = []
        /// Bu sıranın altındaki bağlantı açıkları geçersiz (bağlantı içinde bağlantı yok).
        private var linksDisabledBelow = 0
        private var buffer = ""
        private var backtickRuns: [Int: [Int]]?
        private var backtickCursor: [Int: Int] = [:]

        init(_ text: String, definitions: [String: LinkDefinition]) {
            characters = Array(text)
            self.definitions = definitions
        }

        func render() -> String {
            var i = 0
            let count = characters.count
            while i < count {
                let character = characters[i]
                switch character {
                case "\\":
                    if i + 1 < count, characters[i + 1] == "\n" {
                        trimTrailingSpaces()
                        buffer += "<br />\n"
                        i = skipSpaces(from: i + 2)
                    } else if i + 1 < count, Self.isASCIIPunctuation(characters[i + 1]) {
                        buffer += Self.escape(characters[i + 1])
                        i += 2
                    } else {
                        buffer += "\\"
                        i += 1
                    }
                case "`":
                    i = codeSpan(at: i)
                case "*", "_", "~":
                    i = delimiterRun(at: i)
                case "[":
                    openBracket(image: false, at: i, source: i + 1)
                    i += 1
                case "!" where i + 1 < count && characters[i + 1] == "[":
                    openBracket(image: true, at: i, source: i + 2)
                    i += 2
                case "]":
                    i = closeBracket(at: i)
                case "<":
                    i = angle(at: i)
                case "&":
                    i = entity(at: i)
                case "\n":
                    let spaces = trimTrailingSpaces()
                    buffer += spaces >= 2 ? "<br />\n" : "\n"
                    i = skipSpaces(from: i + 1)
                case "h", "H", "w", "W":
                    if let end = bareLink(at: i) {
                        i = end
                    } else {
                        buffer += String(character)
                        i += 1
                    }
                default:
                    buffer += Self.escape(character)
                    i += 1
                }
            }
            flush()
            processEmphasis(bottom: 0)
            return assemble(0..<pieces.count)
        }

        // MARK: Parçalar

        private func flush() {
            guard !buffer.isEmpty else { return }
            pieces.append(Piece(text: buffer))
            buffer = ""
        }

        @discardableResult
        private func trimTrailingSpaces() -> Int {
            var spaces = 0
            while buffer.last == " " {
                buffer.removeLast()
                spaces += 1
            }
            return spaces
        }

        private func skipSpaces(from index: Int) -> Int {
            var i = index
            while i < characters.count, characters[i] == " " || characters[i] == "\t" { i += 1 }
            return i
        }

        private func assemble(_ range: Range<Int>) -> String {
            var out = ""
            for index in range {
                let piece = pieces[index]
                for tag in piece.closing { out += tag }
                if let delimiter = piece.delimiter {
                    out += String(repeating: delimiters[delimiter].character, count: delimiters[delimiter].count)
                } else {
                    out += piece.text
                }
                for tag in piece.opening.reversed() { out += tag }
            }
            return out
        }

        // MARK: Kod

        private func codeSpan(at start: Int) -> Int {
            var end = start
            while end < characters.count, characters[end] == "`" { end += 1 }
            let length = end - start
            if let close = backtickRun(length: length, after: end) {
                var content = String(characters[end..<close]).replacingOccurrences(of: "\n", with: " ")
                if content.count >= 2, content.first == " ", content.last == " ", !content.allSatisfy({ $0 == " " }) {
                    content = String(content.dropFirst().dropLast())
                }
                buffer += "<code>" + Self.escape(content) + "</code>"
                return close + length
            }
            buffer += String(repeating: "`", count: length)
            return end
        }

        /// Aynı uzunlukta kapanış dizisi. Diziler bir kez çıkarılır; her uzunluk
        /// için imleç yalnızca ileri gider (çok sayıda açık `` ` `` kare büyümez).
        private func backtickRun(length: Int, after position: Int) -> Int? {
            if backtickRuns == nil {
                var runs: [Int: [Int]] = [:]
                var i = 0
                while i < characters.count {
                    if characters[i] == "`" {
                        let start = i
                        while i < characters.count, characters[i] == "`" { i += 1 }
                        runs[i - start, default: []].append(start)
                    } else {
                        i += 1
                    }
                }
                backtickRuns = runs
            }
            guard let starts = backtickRuns?[length] else { return nil }
            var cursor = backtickCursor[length] ?? 0
            while cursor < starts.count, starts[cursor] < position { cursor += 1 }
            backtickCursor[length] = cursor
            return cursor < starts.count ? starts[cursor] : nil
        }

        // MARK: Vurgu

        private func delimiterRun(at start: Int) -> Int {
            let character = characters[start]
            var end = start
            while end < characters.count, characters[end] == character { end += 1 }
            let count = end - start
            if character == "~", count > 2 {
                buffer += String(repeating: "~", count: count)
                return end
            }
            let before: Character = start > 0 ? characters[start - 1] : "\n"
            let after: Character = end < characters.count ? characters[end] : "\n"
            let beforeSpace = before.isWhitespace, afterSpace = after.isWhitespace
            let beforePunctuation = Self.isPunctuation(before), afterPunctuation = Self.isPunctuation(after)
            let left = !afterSpace && (!afterPunctuation || beforeSpace || beforePunctuation)
            let right = !beforeSpace && (!beforePunctuation || afterSpace || afterPunctuation)
            var canOpen = left, canClose = right
            if character == "_" {
                canOpen = left && (!right || beforePunctuation)
                canClose = right && (!left || afterPunctuation)
            }
            flush()
            let index = delimiters.count
            pieces.append(Piece(text: "", delimiter: index))
            delimiters.append(Delimiter(piece: pieces.count - 1, character: character, count: count, original: count,
                                        canOpen: canOpen, canClose: canClose, previous: tail, next: -1))
            if tail >= 0 { delimiters[tail].next = index }
            tail = index
            return end
        }

        private func unlink(_ index: Int) {
            let previous = delimiters[index].previous, next = delimiters[index].next
            if previous >= 0 { delimiters[previous].next = next }
            if next >= 0 { delimiters[next].previous = previous } else { tail = previous }
            delimiters[index].previous = -1
            delimiters[index].next = -1
        }

        /// CommonMark "process emphasis": `bottom` sırasından sonraki ayraçlar.
        private func processEmphasis(bottom: Int) {
            var first = -1
            var cursor = tail
            while cursor >= bottom { first = cursor; cursor = delimiters[cursor].previous }
            var openersBottom: [Int: Int] = [:]
            var closer = first
            while closer >= 0 {
                let current = delimiters[closer]
                guard current.canClose else { closer = current.next; continue }
                let key = Self.bottomKey(current)
                let floor = max(openersBottom[key] ?? (bottom - 1), bottom - 1)
                var opener = current.previous
                var found = false
                while opener > floor {
                    let candidate = delimiters[opener]
                    if candidate.character == current.character, candidate.canOpen, candidate.count > 0 {
                        if current.character == "~" {
                            if candidate.count == current.count { found = true; break }
                        } else {
                            let bothWays = candidate.canClose || current.canOpen
                            let sum = candidate.original + current.original
                            let oddMatch = bothWays && sum % 3 == 0 && !(candidate.original % 3 == 0 && current.original % 3 == 0)
                            if !oddMatch { found = true; break }
                        }
                    }
                    opener = candidate.previous
                }
                if found {
                    let use: Int
                    let tag: String
                    if current.character == "~" {
                        use = current.count
                        tag = "del"
                    } else {
                        use = delimiters[opener].count >= 2 && current.count >= 2 ? 2 : 1
                        tag = use == 2 ? "strong" : "em"
                    }
                    delimiters[opener].count -= use
                    delimiters[closer].count -= use
                    pieces[delimiters[opener].piece].opening.append("<\(tag)>")
                    pieces[delimiters[closer].piece].closing.append("</\(tag)>")
                    var between = delimiters[opener].next
                    while between != closer, between >= 0 {
                        let next = delimiters[between].next
                        unlink(between)
                        between = next
                    }
                    if delimiters[opener].count == 0 { unlink(opener) }
                    if delimiters[closer].count == 0 {
                        let next = delimiters[closer].next
                        unlink(closer)
                        closer = next
                    }
                } else {
                    openersBottom[key] = current.previous
                    let next = current.next
                    if !current.canOpen { unlink(closer) }
                    closer = next
                }
            }
            var index = tail
            while index >= bottom {
                let previous = delimiters[index].previous
                unlink(index)
                index = previous
            }
        }

        private static func bottomKey(_ delimiter: Delimiter) -> Int {
            let base: Int
            switch delimiter.character {
            case "*": base = 0
            case "_": base = 1
            default: base = 2
            }
            return base * 8 + (delimiter.canOpen ? 4 : 0) + delimiter.original % 3
        }

        // MARK: Bağlantı ve görsel

        private func openBracket(image: Bool, at index: Int, source: Int) {
            flush()
            // Yığından düşenler artık engelli değil; yeni açık her zaman geçerli.
            linksDisabledBelow = min(linksDisabledBelow, brackets.count)
            pieces.append(Piece(text: image ? "![" : "["))
            brackets.append(Bracket(piece: pieces.count - 1, isImage: image, source: source, delimiterBottom: delimiters.count))
        }

        private func closeBracket(at index: Int) -> Int {
            guard let bracket = brackets.last else {
                buffer += "]"
                return index + 1
            }
            if !bracket.isImage, brackets.count - 1 < linksDisabledBelow {
                brackets.removeLast()
                buffer += "]"
                return index + 1
            }
            var target: (url: String, title: String?)?
            var end = index + 1
            if let inlineLink = inlineDestination(after: index + 1) {
                target = (inlineLink.url, inlineLink.title)
                end = inlineLink.end
            } else {
                let labelText = String(characters[bracket.source..<index])
                var label = labelText
                if index + 1 < characters.count, characters[index + 1] == "[", let reference = referenceLabel(at: index + 1) {
                    if !reference.label.isEmpty { label = reference.label }
                    if let definition = definitions[Line.normalizedLabel(label)] {
                        target = (definition.url, definition.title)
                        end = reference.end
                    }
                } else if labelText.count <= 999, let definition = definitions[Line.normalizedLabel(label)] {
                    target = (definition.url, definition.title)
                }
            }
            guard let target else {
                brackets.removeLast()
                buffer += "]"
                return index + 1
            }
            flush()
            processEmphasis(bottom: bracket.delimiterBottom)
            let url = Self.safeURL(target.url, image: bracket.isImage)
            let title = target.title.map { " title=\"\(Self.escape($0))\"" } ?? ""
            if bracket.isImage {
                let alt = Self.plainText(assemble((bracket.piece + 1)..<pieces.count))
                for k in (bracket.piece + 1)..<pieces.count { pieces[k] = Piece(text: "") }
                let source = url.map { " src=\"\(Self.escape($0))\"" } ?? ""
                pieces[bracket.piece].text = "<img\(source) alt=\"\(alt)\"\(title) />"
            } else {
                let href = url.map { " href=\"\(Self.escape($0))\"" } ?? ""
                pieces[bracket.piece].text = "<a\(href)\(title)>"
                pieces.append(Piece(text: "</a>"))
                linksDisabledBelow = brackets.count - 1
            }
            brackets.removeLast()
            return end
        }

        /// `(adres "başlık")`; tarama `scanLimit` ile sınırlı.
        private func inlineDestination(after start: Int) -> (url: String, title: String?, end: Int)? {
            let count = characters.count
            let limit = min(count, start + MarkdownRenderer.scanLimit)
            guard start < count, characters[start] == "(" else { return nil }
            var i = skipWhitespace(from: start + 1, limit: limit)
            var url = ""
            if i < limit, characters[i] == "<" {
                i += 1
                while i < limit, characters[i] != ">" {
                    if characters[i] == "\n" || characters[i] == "<" { return nil }
                    if characters[i] == "\\", i + 1 < limit, Self.isASCIIPunctuation(characters[i + 1]) {
                        url.append(characters[i + 1])
                        i += 2
                        continue
                    }
                    url.append(characters[i])
                    i += 1
                }
                guard i < limit else { return nil }
                i += 1
            } else {
                var depth = 0
                while i < limit {
                    let character = characters[i]
                    if character.isWhitespace || character.asciiValue.map({ $0 < 0x20 }) == true { break }
                    if character == "\\", i + 1 < limit, Self.isASCIIPunctuation(characters[i + 1]) {
                        url.append(characters[i + 1])
                        i += 2
                        continue
                    }
                    if character == "(" {
                        depth += 1
                        if depth > 32 { return nil }
                    } else if character == ")" {
                        if depth == 0 { break }
                        depth -= 1
                    }
                    url.append(character)
                    i += 1
                }
                guard depth == 0 else { return nil }
            }
            let beforeTitle = i
            i = skipWhitespace(from: i, limit: limit)
            var title: String?
            if i < limit, i > beforeTitle, "\"'(".contains(characters[i]) {
                let close: Character = characters[i] == "(" ? ")" : characters[i]
                var text = ""
                i += 1
                while i < limit, characters[i] != close {
                    if characters[i] == "\\", i + 1 < limit, Self.isASCIIPunctuation(characters[i + 1]) {
                        text.append(characters[i + 1])
                        i += 2
                        continue
                    }
                    text.append(characters[i])
                    i += 1
                }
                guard i < limit else { return nil }
                title = text
                i = skipWhitespace(from: i + 1, limit: limit)
            }
            guard i < limit, characters[i] == ")" else { return nil }
            return (url, title, i + 1)
        }

        private func skipWhitespace(from index: Int, limit: Int) -> Int {
            var i = index
            var newlines = 0
            while i < limit, characters[i] == " " || characters[i] == "\t" || characters[i] == "\n" {
                if characters[i] == "\n" {
                    newlines += 1
                    if newlines > 1 { break }
                }
                i += 1
            }
            return i
        }

        /// `[etiket]` (tam ya da boş `[]`).
        private func referenceLabel(at start: Int) -> (label: String, end: Int)? {
            var i = start + 1
            var label = ""
            let limit = min(characters.count, start + 1001)
            while i < limit {
                let character = characters[i]
                if character == "]" { return (label, i + 1) }
                if character == "[" { return nil }
                if character == "\\", i + 1 < limit {
                    label.append(character)
                    label.append(characters[i + 1])
                    i += 2
                    continue
                }
                label.append(character)
                i += 1
            }
            return nil
        }

        // MARK: <…>, &…;, çıplak bağlantı

        private func angle(at start: Int) -> Int {
            if let link = autolink(at: start) {
                if let url = Self.safeURL(link.url, image: false) {
                    buffer += "<a href=\"\(Self.escape(url))\">\(Self.escape(link.text))</a>"
                } else {
                    buffer += Self.escape(link.text)
                }
                return link.end
            }
            if let end = Self.tagEnd(characters, at: start) {
                buffer += String(characters[start..<end])
                return end
            }
            buffer += "&lt;"
            return start + 1
        }

        private func autolink(at start: Int) -> (url: String, text: String, end: Int)? {
            let limit = min(characters.count, start + MarkdownRenderer.scanLimit)
            var i = start + 1
            var content = ""
            while i < limit, characters[i] != ">" {
                let character = characters[i]
                if character.isWhitespace || character == "<" || character.asciiValue.map({ $0 < 0x20 }) == true { return nil }
                content.append(character)
                i += 1
            }
            guard i < limit, !content.isEmpty else { return nil }
            if let colon = content.firstIndex(of: ":") {
                let scheme = content[..<colon]
                if (2...32).contains(scheme.count), let first = scheme.first, first.isASCII, first.isLetter,
                   scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }) {
                    return (content, content, i + 1)
                }
            }
            if Self.isEmail(content) { return ("mailto:" + content, content, i + 1) }
            return nil
        }

        private static func isEmail(_ text: String) -> Bool {
            let parts = text.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
            let localAllowed = ".!#$%&'*+/=?^_`{|}~-"
            guard parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || localAllowed.contains($0)) }) else { return false }
            return parts[1].split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
                !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                    && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }
        }

        /// Ham HTML etiketi, kapanış etiketi ya da yorum; bitiş sırası.
        static func tagEnd(_ characters: [Character], at start: Int) -> Int? {
            let count = characters.count
            let limit = min(count, start + MarkdownRenderer.scanLimit)
            guard start + 1 < limit, characters[start] == "<" else { return nil }
            func isNameStart(_ c: Character) -> Bool { c.isASCII && c.isLetter }
            func isNameCharacter(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "-") }
            var i = start + 1
            if characters[i] == "!" {
                // Yorum: <!-- … -->
                guard i + 2 < limit, characters[i + 1] == "-", characters[i + 2] == "-" else { return nil }
                i += 3
                while i + 2 < limit {
                    if characters[i] == "-", characters[i + 1] == "-", characters[i + 2] == ">" { return i + 3 }
                    i += 1
                }
                return nil
            }
            if characters[i] == "/" {
                i += 1
                guard i < limit, isNameStart(characters[i]) else { return nil }
                while i < limit, isNameCharacter(characters[i]) { i += 1 }
                while i < limit, characters[i].isWhitespace { i += 1 }
                return i < limit && characters[i] == ">" ? i + 1 : nil
            }
            guard isNameStart(characters[i]) else { return nil }
            while i < limit, isNameCharacter(characters[i]) { i += 1 }
            while i < limit {
                let spaceStart = i
                while i < limit, characters[i].isWhitespace { i += 1 }
                guard i < limit else { return nil }
                if characters[i] == ">" { return i + 1 }
                if characters[i] == "/" { return i + 1 < limit && characters[i + 1] == ">" ? i + 2 : nil }
                // Öznitelik: önünde boşluk şart.
                guard i > spaceStart else { return nil }
                let nameStart = characters[i]
                guard nameStart.isASCII, nameStart.isLetter || nameStart == "_" || nameStart == ":" else { return nil }
                while i < limit, characters[i].isASCII,
                      characters[i].isLetter || characters[i].isNumber || "_.:-".contains(characters[i]) { i += 1 }
                var j = i
                while j < limit, characters[j].isWhitespace { j += 1 }
                guard j < limit, characters[j] == "=" else { continue }
                j += 1
                while j < limit, characters[j].isWhitespace { j += 1 }
                guard j < limit else { return nil }
                let quote = characters[j]
                if quote == "\"" || quote == "'" {
                    j += 1
                    while j < limit, characters[j] != quote { j += 1 }
                    guard j < limit else { return nil }
                    i = j + 1
                } else {
                    let valueStart = j
                    while j < limit, !characters[j].isWhitespace, !"\"'=<>`".contains(characters[j]) { j += 1 }
                    guard j > valueStart else { return nil }
                    i = j
                }
            }
            return nil
        }

        private func entity(at start: Int) -> Int {
            let limit = min(characters.count, start + 34)
            var i = start + 1
            if i < limit, characters[i] == "#" {
                i += 1
                let hex = i < limit && (characters[i] == "x" || characters[i] == "X")
                if hex { i += 1 }
                let digitsStart = i
                while i < limit, characters[i].isASCII, hex ? characters[i].isHexDigit : characters[i].isNumber { i += 1 }
                let digits = i - digitsStart
                if digits >= 1, digits <= (hex ? 6 : 7), i < limit, characters[i] == ";" {
                    buffer += String(characters[start...i])
                    return i + 1
                }
            } else {
                let nameStart = i
                while i < limit, characters[i].isASCII, characters[i].isLetter || characters[i].isNumber { i += 1 }
                if i - nameStart >= 2, characters[nameStart].isLetter, i < limit, characters[i] == ";" {
                    buffer += String(characters[start...i])
                    return i + 1
                }
            }
            buffer += "&amp;"
            return start + 1
        }

        /// GitHub'ın çıplak bağlantısı: `https://…`, `http://…`, `www.…`.
        private func bareLink(at start: Int) -> Int? {
            guard brackets.isEmpty else { return nil }
            if start > 0 {
                let before = characters[start - 1]
                guard before.isWhitespace || "*_~(".contains(before) else { return nil }
            }
            let prefixes = ["https://", "http://", "www."]
            guard let prefix = prefixes.first(where: { hasPrefix($0, at: start) }) else { return nil }
            let limit = min(characters.count, start + MarkdownRenderer.scanLimit)
            var end = start + prefix.count
            while end < limit, !characters[end].isWhitespace, characters[end] != "<" { end += 1 }
            // Sondaki noktalama bağlantıya dahil değil; dengesiz `)` da.
            while end > start + prefix.count {
                let last = characters[end - 1]
                if "?!.,:*_~'\"".contains(last) {
                    end -= 1
                } else if last == ")" {
                    let slice = characters[start..<end]
                    if slice.filter({ $0 == ")" }).count > slice.filter({ $0 == "(" }).count { end -= 1 } else { break }
                } else {
                    break
                }
            }
            let text = String(characters[start..<end])
            let domain = text.dropFirst(prefix.count).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            guard !domain.isEmpty, prefix != "www." || domain.contains("."),
                  domain.allSatisfy({ $0.isLetter || $0.isNumber || "-._:".contains($0) }) else { return nil }
            let url = prefix == "www." ? "http://" + text : text
            buffer += "<a href=\"\(Self.escape(url))\">\(Self.escape(text))</a>"
            return end
        }

        private func hasPrefix(_ prefix: String, at start: Int) -> Bool {
            var i = start
            for expected in prefix {
                guard i < characters.count, characters[i].lowercased() == String(expected) else { return false }
                i += 1
            }
            return true
        }

        // MARK: Yardımcılar

        static func escape(_ character: Character) -> String {
            switch character {
            case "&": return "&amp;"
            case "<": return "&lt;"
            case ">": return "&gt;"
            case "\"": return "&quot;"
            default: return String(character)
            }
        }

        static func escape(_ text: String) -> String {
            var out = ""
            out.reserveCapacity(text.count)
            for character in text { out += escape(character) }
            return out
        }

        static func unescape(_ text: String) -> String {
            guard text.contains("\\") else { return text }
            var out = ""
            var escaped = false
            for character in text {
                if escaped {
                    if !isASCIIPunctuation(character) { out.append("\\") }
                    out.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else {
                    out.append(character)
                }
            }
            if escaped { out.append("\\") }
            return out
        }

        /// Görselin `alt` metni: içteki etiketler atılır (metin zaten kaçışlı).
        static func plainText(_ html: String) -> String {
            var out = ""
            var inTag = false
            for character in html {
                if character == "<" { inTag = true } else if character == ">" { inTag = false } else if !inTag { out.append(character) }
            }
            return out.replacingOccurrences(of: "\"", with: "&quot;")
        }

        static func isASCIIPunctuation(_ character: Character) -> Bool {
            guard let value = character.asciiValue else { return false }
            return (0x21...0x2F).contains(value) || (0x3A...0x40).contains(value)
                || (0x5B...0x60).contains(value) || (0x7B...0x7E).contains(value)
        }

        static func isPunctuation(_ character: Character) -> Bool {
            character.isPunctuation || character.isSymbol
        }

        /// Tehlikeli şemalar düşer: `javascript:`, `vbscript:`, `file:`, görsel
        /// olmayan `data:`. Boşluk `%20` olur. `nil`: adres yazılmaz.
        static func safeURL(_ raw: String, image: Bool) -> String? {
            let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let compact = url.lowercased().filter { !$0.isWhitespace && $0.asciiValue.map({ $0 >= 0x20 }) ?? true }
            for scheme in ["javascript:", "vbscript:", "file:"] where compact.hasPrefix(scheme) { return nil }
            if compact.hasPrefix("data:") {
                let allowed = ["data:image/png", "data:image/gif", "data:image/jpeg", "data:image/webp"]
                guard image, allowed.contains(where: { compact.hasPrefix($0) }) else { return nil }
            }
            return url.replacingOccurrences(of: " ", with: "%20")
        }
    }
}
