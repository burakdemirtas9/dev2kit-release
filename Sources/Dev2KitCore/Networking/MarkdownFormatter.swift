import Foundation

/// Markdown biçimlendirici ve yapısal kontrol.
///
/// Markdown'da "geçersiz" pek yoktur; biçimlendirme normalizasyondur:
/// - Kod bloğu (``` / ~~~) içine dokunulmaz.
/// - Satır sonundaki 2+ boşluk zorunlu satır sonudur (hard break): tam iki
///   boşluk olarak korunur; diğer sondaki boşluklar atılır.
/// - Başlık: `##   Başlık` → `## Başlık`; önünde/arkasında boş satır.
///   `#Başlık` başlığa ÇEVRİLMEZ: CommonMark'ta düz metindir (`#123 hatası`,
///   `#etiket`); çevirmek belgenin anlamını değiştirirdi.
/// - Liste işareti `*`/`+` → `-` (yatay çizgi `* * *` hariç).
/// - Tablo sütunları hizalanır, `:---:` hizalaması korunur.
/// - Art arda boş satırlar teke iner.
///
/// Sütun genişliği karakter sayısıyla hesaplanır (eşit genişlikli yazı tipi
/// varsayımı); emoji/geniş karakterlerde hizalama bir-iki karakter kayabilir.
public enum MarkdownFormatter {
    static let language = "Markdown"

    public static func beautify(_ text: String) throws -> String {
        let lines = try BeautifyError.requireContent(text, language: language)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var out: [String] = []
        var index = 0

        func pushBlank() {
            if let last = out.last, !last.isEmpty { out.append("") }
        }

        while index < lines.count {
            let line = lines[index]
            if let fence = fenceMarker(line) {
                // Kod bloğu: kapanışa kadar olduğu gibi.
                out.append(line.trimmingTrailingWhitespace)
                index += 1
                while index < lines.count {
                    out.append(lines[index])
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { index += 1; break }
                    index += 1
                }
                continue
            }
            if let table = tableBlock(lines, from: index) {
                out.append(contentsOf: alignTable(Array(lines[index..<table])))
                index = table
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                pushBlank()
                index += 1
                continue
            }
            if let heading = normalizedHeading(line) {
                pushBlank()
                out.append(heading)
                out.append("")
                index += 1
                continue
            }
            out.append(normalizedLine(line))
            index += 1
        }
        while out.last?.isEmpty == true { out.removeLast() }
        while out.first?.isEmpty == true { out.removeFirst() }
        // Başlıktan sonra eklenen boş satır, ardından gelen boş satırla teke iner.
        return out.reduce(into: [String]()) { result, line in
            if line.isEmpty, result.last?.isEmpty == true { return }
            result.append(line)
        }.joined(separator: "\n")
    }

    /// Kapanmamış kod bloğu ve sütun sayısı tutmayan tablo. Sonuç
    /// `.structurallyValid`: arayüz "geçerli" DEMEZ.
    public static func check(_ text: String) -> WorkbenchValidation {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        func issue(_ message: String, line: Int) -> WorkbenchValidation {
            .invalid(.at(line: line + 1, column: 1, in: text, message: "Markdown: \(message)"))
        }
        while index < lines.count {
            if let fence = fenceMarker(lines[index]) {
                let start = index
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { index += 1 }
                guard index < lines.count else { return issue("kod bloğu (\(fence)) kapatılmamış", line: start) }
                index += 1
                continue
            }
            if let end = tableBlock(lines, from: index) {
                let columns = cells(lines[index]).count
                for row in index..<end where cells(lines[row]).count != columns {
                    return issue("tablo satırında \(cells(lines[row]).count) sütun var, başlıkta \(columns)", line: row)
                }
                index = end
                continue
            }
            index += 1
        }
        return .structurallyValid
    }

    // MARK: - Satırlar

    private static func fenceMarker(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    /// `##   Başlık` → `## Başlık`; başlık değilse (`#etiket`) nil.
    private static func normalizedHeading(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let afterHashes = trimmed.dropFirst(hashes.count)
        guard afterHashes.isEmpty || afterHashes.first == " " || afterHashes.first == "\t" else { return nil }
        let rest = afterHashes.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? String(hashes) : "\(hashes) \(rest)"
    }

    private static func normalizedLine(_ line: String) -> String {
        let hardBreak = line.hasSuffix("  ") && !line.trimmingCharacters(in: .whitespaces).isEmpty
        var result = line.trimmingTrailingWhitespace
        let indent = result.prefix { $0 == " " || $0 == "\t" }
        let body = result.dropFirst(indent.count)
        let isRule = body.filter { !$0.isWhitespace }.count >= 3
            && Set(body.filter { !$0.isWhitespace }).count == 1
            && ["*", "-", "_"].contains(body.first)
        if !isRule, let marker = body.first, marker == "*" || marker == "+", body.dropFirst().first == " " {
            result = indent + "-" + body.dropFirst()
        }
        return hardBreak ? result + "  " : result
    }

    // MARK: - Tablo

    /// `from`'da başlayan tablonun bitiş satırı (dahil değil); tablo değilse nil.
    /// İkinci satır ayraç (`| --- | :-: |`) olmalı.
    private static func tableBlock(_ lines: [String], from index: Int) -> Int? {
        guard index + 1 < lines.count, lines[index].contains("|"), isSeparator(lines[index + 1]) else { return nil }
        var end = index + 2
        while end < lines.count, lines[end].contains("|"), !lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
        return end
    }

    private static func isSeparator(_ line: String) -> Bool {
        let parts = cells(line)
        return !parts.isEmpty && parts.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    /// Satırın hücreleri; baştaki/sondaki `|` atılır, `\|` ve kod içindeki `|` bölmez.
    static func cells(_ line: String) -> [String] {
        var trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
        if trimmed.hasPrefix("|") { trimmed = trimmed.dropFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed = trimmed.dropLast() }
        var result: [String] = []
        var current = ""
        var inCode = false
        var previous: Character?
        for ch in trimmed {
            if ch == "`" { inCode.toggle() }
            if ch == "|", previous != "\\", !inCode {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
            previous = ch
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    private enum Alignment { case left, center, right, none }

    private static func alignTable(_ rows: [String]) -> [String] {
        let header = cells(rows[0])
        let alignments: [Alignment] = cells(rows[1]).map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .right
            case (true, false): return .left
            default: return .none
            }
        }
        let body = rows.dropFirst(2).map(cells)
        let columns = max(header.count, alignments.count, body.map(\.count).max() ?? 0)
        func cell(_ row: [String], _ column: Int) -> String { column < row.count ? row[column] : "" }
        let widths = (0..<columns).map { column in
            max(3, ([header] + body).map { cell($0, column).count }.max() ?? 0)
        }
        func pad(_ text: String, _ column: Int) -> String {
            let space = widths[column] - text.count
            switch column < alignments.count ? alignments[column] : .none {
            case .right: return String(repeating: " ", count: space) + text
            case .center:
                let left = space / 2
                return String(repeating: " ", count: left) + text + String(repeating: " ", count: space - left)
            default: return text + String(repeating: " ", count: space)
            }
        }
        func render(_ row: [String]) -> String {
            "| " + (0..<columns).map { pad(cell(row, $0), $0) }.joined(separator: " | ") + " |"
        }
        let separator = "| " + (0..<columns).map { column -> String in
            let width = widths[column]
            switch column < alignments.count ? alignments[column] : .none {
            case .center: return ":" + String(repeating: "-", count: width - 2) + ":"
            case .right: return String(repeating: "-", count: width - 1) + ":"
            case .left: return ":" + String(repeating: "-", count: width - 1)
            case .none: return String(repeating: "-", count: width)
            }
        }.joined(separator: " | ") + " |"
        return [render(header), separator] + body.map(render)
    }
}

private extension String {
    var trimmingTrailingWhitespace: String {
        var result = self
        while let last = result.last, last == " " || last == "\t" { result.removeLast() }
        return result
    }
}
