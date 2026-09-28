import Foundation

/// Metinde katlanabilir `{...}` / `[...]` bölgeleri.
///
/// Neden Core'da: "hangi parantez hangisiyle eşleşir, dizgi içindeki parantez
/// sayılmaz" kuralı davranıştır ve test edilmesi gerekir. Arayüz yalnızca
/// çizer.
///
/// Ayrıştırıcı bilinçli olarak gevşek: geçersiz JSON'da da çalışır. Kullanıcı
/// yazarken metin çoğu zaman yarımdır; katlama o sırada da bozulmamalı.
public enum JSONFolding {
    /// Bölge tipi dilden bağımsız; XML-HTML tarafı aynısını kullanıyor.
    public typealias Region = FoldRegion

    /// Tek satırda başlayıp biten bloklar katlanmaz: katlamanın kazancı yok.
    public static func regions(in text: String) -> [Region] {
        let characters = Array(text.utf16)
        var stack: [(index: Int, line: Int, kind: Region.Kind)] = []
        var regions: [Region] = []
        var line = 0
        var inString = false
        var escaped = false

        for (index, unit) in characters.enumerated() {
            let character = Character(UnicodeScalar(unit) ?? " ")

            if escaped {
                escaped = false
                continue
            }
            if inString {
                if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                else if character == "\n" { line += 1 }   // bozuk JSON'da satır kaçmasın
                continue
            }

            switch character {
            case "\"": inString = true
            case "\n": line += 1
            case "{": stack.append((index, line, .object))
            case "[": stack.append((index, line, .array))
            case "}", "]":
                guard let open = stack.popLast() else { continue }
                guard line > open.line else { continue }   // tek satırlık blok
                guard let hidden = Region.hiddenRange(
                    from: open.index + 1,
                    to: index,
                    in: characters
                ) else { continue }
                regions.append(
                    Region(
                        openLine: open.line,
                        closeLine: line,
                        hiddenRange: hidden,
                        kind: open.kind
                    )
                )
            default:
                break
            }
        }

        // Dıştan içe sıra: arayüz "tümünü kapat"ta önce dış bloğu işler.
        return regions.sorted { $0.hiddenRange.location < $1.hiddenRange.location }
    }
}
