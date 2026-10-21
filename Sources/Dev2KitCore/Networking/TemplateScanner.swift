import Foundation

/// `{{değişken}}` şablonlarını doğrusal zamanda bulur.
///
/// Neden regex değil (güvenlik incelemesi, 2026-10-21): eski desen
/// `\{\{\s*([^{}]+?)\s*\}\}` Swift Regex'te geri izlemeyle patlıyordu. Kapanmayan
/// `{{` ve ardından uzun boşluk: 1.000 karakter 5,8 sn, 2.000 karakter 45 sn,
/// 4.000 karakter 358 sn (ölçüldü). Metin içe aktarılan koleksiyondan, Postman
/// dosyasından ya da Kibana logundan gelebiliyor; gönderim ve vurgulama
/// donuyordu.
///
/// Kural eski desenle BİREBİR aynı (testle karşılaştırılıyor):
/// - `{{`'den sonra ilk süslü paranteze kadar okunur; o `}}` ise eşleşme,
///   `{` ya da tek `}` ise bu başlangıçta eşleşme yoktur.
/// - İçerik boş olamaz. Ad, baştaki ve sondaki boşluk atılmış içeriktir;
///   içerik yalnızca boşluksa ad son boşluk karakteridir (desenin davranışı).
/// - Eşleşmeden sonra aramaya eşleşmenin sonundan, eşleşmezse bir sonraki
///   karakterden devam edilir.
public enum TemplateScanner {
    public struct Match {
        /// `{{` … `}}` dahil.
        public let range: Range<String.Index>
        public let name: Substring
    }

    public static func matches(in text: String) -> [Match] {
        var result: [Match] = []
        var index = text.startIndex
        while let open = text[index...].range(of: "{{") {
            let contentStart = open.upperBound
            // İlk süslü paranteze kadar (yoksa sona).
            var cursor = contentStart
            while cursor < text.endIndex, text[cursor] != "{", text[cursor] != "}" {
                cursor = text.index(after: cursor)
            }
            let closes = cursor < text.endIndex && text[cursor] == "}"
                && text.index(after: cursor) < text.endIndex && text[text.index(after: cursor)] == "}"
            if closes, cursor > contentStart {
                let end = text.index(cursor, offsetBy: 2)
                result.append(Match(range: open.lowerBound..<end, name: name(in: text[contentStart..<cursor])))
                index = end
            } else {
                // Eşleşme yok: bir sonraki karakterden (üst üste `{{{` için).
                index = text.index(after: open.lowerBound)
            }
            if index >= text.endIndex { break }
        }
        return result
    }

    /// Eski desendeki grup: baştaki ve sondaki boşluk hariç; tamamı boşluksa
    /// grup en az bir karakter istediği için son boşluk karakteri.
    private static func name(in content: Substring) -> Substring {
        guard let first = content.firstIndex(where: { !$0.isWhitespace }),
              let last = content.lastIndex(where: { !$0.isWhitespace }) else {
            return content[content.index(before: content.endIndex)...]
        }
        return content[first...last]
    }
}
