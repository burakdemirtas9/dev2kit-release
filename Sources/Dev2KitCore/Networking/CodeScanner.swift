import Foundation

/// Biçimlendiricilerin ortak karakter tarayıcısı.
///
/// JSON, JavaScript ve XML/HTML biçimlendiricileri aynı alt işleri yapıyor:
/// tırnaklı metni kaçışlara saygıyla atlamak, yorumu tanıyıp olduğu gibi
/// korumak, bir kapanış dizisini bulmak. Her biri bunu ayrı yazınca yorum
/// desteği birinde olup diğerinde olmuyordu (JSON'da tek bir `//` biçimlendirmeyi
/// düşürüyordu). Yeni bir biçimlendirici bu parçaları kullanır, yeniden yazmaz;
/// çıktı tarafı `IndentedWriter`, hata tipi `BeautifyError`.
struct CodeScanner {
    /// Kaynaktaki bir yorum, metni olduğu gibi.
    struct Comment: Equatable {
        enum Style { case line, block }

        let text: String
        let style: Style
        /// Kaynakta aynı satırda kendinden önce kod var: `foo(); // açıklama`.
        /// Biçimlendirilmiş çıktıda da kodun yanında kalır.
        let isTrailing: Bool
    }

    let chars: [Character]
    var index = 0

    init(_ text: String) {
        chars = Array(text)
    }

    init(chars: [Character], index: Int = 0) {
        self.chars = chars
        self.index = index
    }

    var isAtEnd: Bool { index >= chars.count }
    var current: Character { chars[index] }

    func peek(_ offset: Int = 1) -> Character? {
        let position = index + offset
        return position < chars.count ? chars[position] : nil
    }

    func hasPrefix(_ prefix: String, at position: Int? = nil) -> Bool {
        var i = position ?? index
        for ch in prefix {
            guard i < chars.count, chars[i] == ch else { return false }
            i += 1
        }
        return true
    }

    /// `position`dan sonraki ilk boşluk olmayan karakter.
    func nextNonWhitespace(after position: Int) -> Character? {
        var i = position
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        return i < chars.count ? chars[i] : nil
    }

    /// `terminator`ün SON karakterinin konumu; bulunamazsa nil.
    func position(of terminator: String, from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if hasPrefix(terminator, at: i) { return i + terminator.count - 1 }
            i += 1
        }
        return nil
    }

    /// Bu konumdan önce aynı satırda yalnızca boşluk mu var?
    func startsLine(at position: Int) -> Bool {
        var i = position - 1
        while i >= 0 {
            if chars[i].isNewline { return true }
            if !chars[i].isWhitespace { return false }
            i -= 1
        }
        return true
    }

    /// Konumda `//` ya da `/* */` yorumu varsa okur ve geçer; yoksa nil.
    /// `/*` kapatılmamışsa `language` adıyla hata fırlatır.
    mutating func readComment(language: String) throws -> Comment? {
        guard !isAtEnd, current == "/", let next = peek() else { return nil }
        let isTrailing = !startsLine(at: index)
        if next == "/" {
            var end = index
            while end < chars.count, !chars[end].isNewline { end += 1 }
            let text = String(chars[index..<end])
            index = end
            return Comment(text: text.trimmingTrailingWhitespace, style: .line, isTrailing: isTrailing)
        }
        if next == "*" {
            guard let end = position(of: "*/", from: index + 2) else {
                throw BeautifyError.invalid(language, "/* yorumu */ ile kapatılmamış.")
            }
            let text = String(chars[index...end])
            index = end + 1
            return Comment(text: text, style: .block, isTrailing: isTrailing)
        }
        return nil
    }

    /// Konumdaki karakterle açılan tırnaklı metni (kaçışlara saygıyla) okur ve
    /// geçer: `"…"`, `'…'`, `` `…` ``, regex `/…/`. Kapanmamışsa nil döner ve
    /// konum değişmez. `multiline` değilse satır sonu kapanmamış sayılır.
    mutating func readQuoted(multiline: Bool) -> String? {
        let open = current
        var i = index + 1
        while i < chars.count {
            if chars[i] == "\\" {
                i += 2
                continue
            }
            if chars[i] == open {
                let text = String(chars[index...i])
                index = i + 1
                return text
            }
            if !multiline, chars[i].isNewline { return nil }
            i += 1
        }
        return nil
    }

    /// Yorumları boşlukla değiştirir; tırnak içindeki `//` (ör. URL) korunur.
    ///
    /// Satır sonları yerinde kalır: doğrulayıcının hata mesajındaki satır/sütun
    /// kullanıcının gördüğü metni göstermeye devam eder. Kapanmamış yorum ya
    /// da tırnakta metin olduğu gibi bırakılır; hatayı doğrulayıcı verir.
    static func strippingComments(_ text: String, quotes: Set<Character> = ["\""]) -> String {
        var scanner = CodeScanner(text)
        var out = ""
        while !scanner.isAtEnd {
            let ch = scanner.current
            if quotes.contains(ch) {
                if let quoted = scanner.readQuoted(multiline: false) {
                    out += quoted
                    continue
                }
                out += String(scanner.chars[scanner.index...])
                break
            }
            if ch == "/" {
                do {
                    if let comment = try scanner.readComment(language: "") {
                        out += String(comment.text.map { $0.isNewline ? $0 : " " })
                        continue
                    }
                } catch {
                    out += String(scanner.chars[scanner.index...])
                    break
                }
            }
            out.append(ch)
            scanner.index += 1
        }
        return out
    }
}

/// Biçimlendiricilerin ortak çıktı yazıcısı: girinti seviyesi, satır sonu ve
/// yorumların yerleşimi.
///
/// Yorum kuralı her dilde aynı (normal beautifier'lar gibi): satır sonu yorumu
/// kodun yanında kalır, kendi satırındaki yorum kendi satırında. Satır
/// yorumundan sonra yazılan her şey yeni satıra iner — aynı satıra yazılsa
/// kod yorumun içine girerdi.
struct IndentedWriter {
    let indent: String
    var level = 0
    private(set) var text = ""
    /// Son yazılan anlamlı (boşluk olmayan) kod karakteri. Yorumlar saymaz;
    /// JS'de `/`nin bölme mi regex mi olduğu buna bakılarak seçiliyor.
    private(set) var lastMeaningful: Character?
    /// Satırı yorum kapattı: sonraki kod yeni satırda başlamalı.
    private var lineClosed = false

    init(indent: String) {
        self.indent = indent
    }

    var isEmpty: Bool { text.isEmpty }

    mutating func append(_ piece: String) {
        var piece = Substring(piece)
        if lineClosed {
            newline()
            piece = piece.drop { $0 == " " }
        }
        text += piece
        if let last = piece.last(where: { !$0.isWhitespace }) { lastMeaningful = last }
    }

    /// Kelimeler arası tek boşluk; satır başında ya da üst üste boşluk yazılmaz.
    mutating func space() {
        guard let last = text.last, last != " ", last != "\n" else { return }
        text += " "
    }

    mutating func trimTrailing() {
        while let last = text.last, last == " " || last == "\n" { text.removeLast() }
    }

    /// Yeni satır ve o anki seviyenin girintisi. Sondaki boşluklar atılır;
    /// boş çıktıda (en baş) satır açılmaz.
    mutating func newline() {
        trimTrailing()
        lineClosed = false
        guard !text.isEmpty else { return }
        text += "\n" + String(repeating: indent, count: level)
    }

    /// Kaynakta aynı satırda duran yorum kodun yanında kalır; kendi satırındaki
    /// yorum kendi satırında. Ardından gelen kod yeni satıra iner; yalnızca
    /// satır içi `/* */` yorumundan sonra aynı satırda devam edilir.
    mutating func comment(_ comment: CodeScanner.Comment) {
        if comment.isTrailing, !text.isEmpty {
            trimTrailing()
            text += " " + comment.text
            if comment.style == .line {
                lineClosed = true
            } else {
                text += " "
            }
        } else {
            newline()
            text += comment.text
            lineClosed = true
        }
    }
}

/// Tüm biçimlendiricilerin hata tipi. Mesaj kullanıcıya olduğu gibi gösterilir.
public struct BeautifyError: Error, LocalizedError, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }

    /// "Geçersiz JSON: …" biçiminde mesaj.
    static func invalid(_ language: String, _ detail: String) -> BeautifyError {
        BeautifyError(message: "Geçersiz \(language): \(detail)")
    }

    /// Baştaki/sondaki boşlukları atılmış içerik; boşsa hata.
    static func requireContent(_ text: String, language: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw invalid(language, "içerik boş") }
        return trimmed
    }
}

private extension String {
    var trimmingTrailingWhitespace: String {
        var result = self
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return result
    }
}
