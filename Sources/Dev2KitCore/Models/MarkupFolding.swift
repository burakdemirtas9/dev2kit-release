import Foundation

/// XML ve HTML'de katlanabilir `<etiket>...</etiket>` bölgeleri.
///
/// `JSONFolding` ile aynı sözleşme (`FoldRegion`) ve aynı gevşeklik felsefesi:
/// yarım ya da bozuk belgede de çalışır, kullanıcı yazarken bozulmaz.
///
/// `XMLDocument` kullanılmadı — `MarkupFormatter`'daki gerekçenin aynısı:
/// HTML'in gevşek yapısını reddediyor. Ayrıca katlama için konum bilgisi
/// gerekiyor, ayrıştırıcı ağacı onu vermiyor.
public enum MarkupFolding {
    /// HTML'de kapanışı olmayan elementler; bölge açmazlar.
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    public static func regions(in text: String) -> [FoldRegion] {
        let characters = Array(text.utf16)
        var stack: [(openEnd: Int, line: Int, name: String)] = []
        var regions: [FoldRegion] = []
        var line = 0
        var index = 0

        while index < characters.count {
            if characters[index] == 10 {   // \n
                line += 1
                index += 1
                continue
            }
            guard characters[index] == 60 else {   // <
                index += 1
                continue
            }

            // Yorum, işlem talimatı, DOCTYPE ve CDATA bölge açmaz; içlerindeki
            // "<" ve ">" etiket sanılmasın diye bir bütün olarak atlanır.
            if let skipped = skipSpecial(from: index, in: characters, line: &line) {
                index = skipped
                continue
            }

            guard let tag = readTag(from: index, in: characters, line: &line) else {
                index += 1
                continue
            }
            index = tag.end

            if tag.isClosing {
                // Eşleşmeyen kapanışta yığını temizle: bozuk HTML'de
                // (kapatılmayan <li> gibi) aradaki açıklar düşer.
                guard let match = stack.lastIndex(where: { $0.name == tag.name }) else { continue }
                let open = stack[match]
                stack.removeSubrange(match...)
                guard tag.line > open.line else { continue }   // tek satırlık element
                guard let hidden = FoldRegion.hiddenRange(
                    from: open.openEnd,
                    to: tag.start,
                    in: characters
                ) else { continue }
                regions.append(
                    FoldRegion(
                        openLine: open.line,
                        closeLine: tag.line,
                        hiddenRange: hidden,
                        kind: .element
                    )
                )
            } else if !tag.isSelfClosing, !voidElements.contains(tag.name) {
                stack.append((openEnd: tag.end, line: tag.line, name: tag.name))
            }
        }

        return regions.sorted { $0.hiddenRange.location < $1.hiddenRange.location }
    }

    // MARK: - Tarama

    private struct Tag {
        let start: Int
        let end: Int
        /// Etiketin BAŞLADIĞI satır; çok satıra yayılan etiketlerde kapanış
        /// satırı değil açılış satırı esas alınır.
        let line: Int
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
    }

    /// `<!-- -->`, `<?...?>`, `<!DOCTYPE>`, `<![CDATA[...]]>` bloklarını atlar.
    /// Atladıysa yeni indeksi, değilse `nil` döner.
    private static func skipSpecial(from start: Int, in characters: [UInt16], line: inout Int) -> Int? {
        func matches(_ text: String, at position: Int) -> Bool {
            let units = Array(text.utf16)
            guard position + units.count <= characters.count else { return false }
            return Array(characters[position..<(position + units.count)]) == units
        }

        let terminator: String
        if matches("<!--", at: start) {
            terminator = "-->"
        } else if matches("<![CDATA[", at: start) {
            terminator = "]]>"
        } else if matches("<?", at: start) {
            terminator = "?>"
        } else if matches("<!", at: start) {
            terminator = ">"
        } else {
            return nil
        }

        let units = Array(terminator.utf16)
        var index = start
        while index < characters.count {
            if characters[index] == 10 { line += 1 }
            if index + units.count <= characters.count,
               Array(characters[index..<(index + units.count)]) == units {
                for offset in index..<(index + units.count) where characters[offset] == 10 { line += 1 }
                return index + units.count
            }
            index += 1
        }
        return characters.count   // kapanmamış: belgenin sonuna kadar atla
    }

    /// `<` konumundan başlayıp `>`'a kadar okur. Tırnak içindeki `>` bitiş
    /// sayılmaz: `<a title="1 > 0">` tek bir etikettir.
    private static func readTag(from start: Int, in characters: [UInt16], line: inout Int) -> Tag? {
        let tagLine = line
        var index = start + 1
        var isClosing = false
        if index < characters.count, characters[index] == 47 {   // /
            isClosing = true
            index += 1
        }

        var name = ""
        while index < characters.count, isNameUnit(characters[index]) {
            name.append(Character(UnicodeScalar(characters[index]) ?? " "))
            index += 1
        }
        guard !name.isEmpty else { return nil }

        var quote: UInt16?
        var previous: UInt16 = 0
        while index < characters.count {
            let unit = characters[index]
            if unit == 10 { line += 1 }
            if let open = quote {
                if unit == open { quote = nil }
            } else if unit == 34 || unit == 39 {   // " '
                quote = unit
            } else if unit == 62 {                 // >
                return Tag(
                    start: start,
                    end: index + 1,
                    line: tagLine,
                    name: name.lowercased(),
                    isClosing: isClosing,
                    isSelfClosing: previous == 47   // /
                )
            }
            previous = unit
            index += 1
        }
        return nil   // kapanmamış etiket
    }

    private static func isNameUnit(_ unit: UInt16) -> Bool {
        // A-Z a-z 0-9 ve : _ - . (ad alanı ve tire içeren etiket adları)
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
            || (unit >= 48 && unit <= 57)
            || unit == 58 || unit == 95 || unit == 45 || unit == 46
    }
}
