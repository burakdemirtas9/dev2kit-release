import AppKit
import XCTest
@testable import Dev2KitApp

/// Renklendirme kuralları `try!` ile derleniyor: hatalı bir regex uygulamayı
/// açılışta değil, o dil ilk boyandığında çökertir. Her dil burada bir kez boyanır.
@MainActor
final class SyntaxHighlighterTests: XCTestCase {
    func testEveryLanguagesRulesCompileAndColor() {
        let samples: [CodeLanguage: String] = [
            .plain: "metin",
            .json: #"{"a": 1, "b": "x", "c": true}"#,
            .markup: #"<a href="x"><!-- y --></a>"#,
            .javascript: "const a = 'x'; // y",
            .css: "a { color: #fff; margin: 0 2px } /* y */",
            .sql: "SELECT a, \"b\", [c] FROM t WHERE x = 'it''s' -- y",
            .markdown: "# Başlık\n- madde `kod` [a](http://x)\n```\nblok\n```",
        ]
        for (language, text) in samples {
            let storage = NSTextStorage(string: text)
            SyntaxHighlighter.colorize(storage, language: language, range: NSRange(location: 0, length: storage.length))
            XCTAssertEqual(storage.string, text, "\(language)")
        }
    }
}

/// 2026-10-18: renklendirme `setAttributes` ile yazı tipini siliyordu; görünen
/// bölge Helvetica 12 ile çiziliyordu (monospace değil, yakınlaştırma etkisiz).
@MainActor
final class SyntaxHighlighterFontTests: XCTestCase {
    func testColorizingKeepsTheEditorFont() {
        let storage = NSTextStorage(string: #"{"a": 1, "b": "x"}"#)
        let font = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
        SyntaxHighlighter.applyBaseAttributes(storage, font: font)
        SyntaxHighlighter.colorize(storage, language: .json, range: NSRange(location: 0, length: storage.length))
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            XCTAssertEqual((value as? NSFont)?.pointSize, 18, "aralık \(range) yazı tipini kaybetti")
        }
    }
}
