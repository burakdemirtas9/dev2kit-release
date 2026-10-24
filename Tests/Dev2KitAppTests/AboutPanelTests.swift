import AppKit
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Hakkında penceresindeki iletişim bilgileri: İletişim panosuyla aynı
/// kaynak, bağlantılar tıklanabilir, çökme raporu bölümü yok.
@MainActor
final class AboutPanelTests: XCTestCase {
    override func invokeTest() { withLanguage(.turkish) { super.invokeTest() } }

    private func links(in text: NSAttributedString) -> [URL] {
        var found: [URL] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL { found.append(url) }
        }
        return found
    }

    func testCreditsShowContactInfoWithLinks() {
        let info = ContactInfo(name: "Ada Lovelace", slackLink: "https://chat.example.test/archives/D1", email: "ada@example.test")
        let credits = AboutPanel.credits(for: info)
        XCTAssertTrue(credits.string.contains("İletişim"))
        XCTAssertTrue(credits.string.contains("Ada Lovelace"))
        XCTAssertTrue(credits.string.contains("Slack'te Aç"))
        XCTAssertTrue(credits.string.contains("ada@example.test"))
        XCTAssertEqual(links(in: credits).map(\.absoluteString), ["https://chat.example.test/archives/D1", "mailto:ada@example.test"])
        XCTAssertFalse(credits.string.lowercased().contains("çökme"), "çökme raporu bölümü yok")
    }

    func testUnavailableChannelsAreNotShown() {
        let credits = AboutPanel.credits(for: ContactInfo(name: "Ada", slackLink: "file:///etc/passwd", email: "geçersiz"))
        XCTAssertTrue(links(in: credits).isEmpty, "geçersiz bağlantı açılmaz")
        XCTAssertFalse(credits.string.contains("Slack:"))
        XCTAssertFalse(credits.string.contains("E-posta:"))
    }

    func testCurrentInfoIsUsedByDefault() {
        let credits = AboutPanel.credits()
        if let name = ContactInfo.current.displayName { XCTAssertTrue(credits.string.contains(name)) }
        XCTAssertEqual(links(in: credits).count, ContactInfo.current.channels.count)
    }
}
