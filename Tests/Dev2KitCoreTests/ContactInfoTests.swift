import XCTest
@testable import Dev2KitCore

/// İletişim panosunun yapılandırması: yalnızca geçerli seçenekler gösterilir,
/// yalnızca güvenli bağlantılar açılır.
final class ContactInfoTests: XCTestCase {
    func testCurrentConfigurationIsComplete() {
        // Değerler burada yazılmaz: yalnızca uygulamadaki yapılandırmanın
        // eksiksiz ve geçerli olduğu doğrulanır.
        let info = ContactInfo.current
        XCTAssertNotNil(info.displayName)
        XCTAssertEqual(info.channels.map(\.kind), [.slack, .email])
        XCTAssertEqual(info.slack.url?.scheme, "https")
        XCTAssertEqual(info.mail.url?.scheme, "mailto")
    }

    func testEmptyConfigurationShowsNoChannels() {
        let info = ContactInfo(name: "  ")
        XCTAssertNil(info.displayName)
        XCTAssertEqual(info.channels, [])
        XCTAssertFalse(info.slack.isAvailable)
        XCTAssertFalse(info.mail.isAvailable)
    }

    func testConfiguredChannels() {
        let info = ContactInfo(name: "Ada Örnek", slackLabel: "#destek",
                               slackLink: "https://chat.example.test/archives/C1", email: "destek@example.test")
        XCTAssertEqual(info.displayName, "Ada Örnek")
        XCTAssertEqual(info.slack.value, "#destek")
        XCTAssertEqual(info.slack.url?.absoluteString, "https://chat.example.test/archives/C1")
        XCTAssertEqual(info.mail.value, "destek@example.test")
        XCTAssertEqual(info.mail.url?.absoluteString, "mailto:destek@example.test")
    }

    func testSlackLinkWithoutLabelShowsLink() {
        let info = ContactInfo(slackLink: "https://chat.example.test/x")
        XCTAssertEqual(info.slack.value, "https://chat.example.test/x")
        XCTAssertEqual(info.channels.map(\.kind), [.slack])
    }

    func testSlackLinkWithoutProtocolUsesHTTPS() {
        XCTAssertEqual(ContactInfo.slackURL("chat.example.test/archives/C1")?.absoluteString,
                       "https://chat.example.test/archives/C1")
        // Görünen ve kopyalanan değer de açılan bağlantıyla aynı.
        XCTAssertEqual(ContactInfo(slackLink: "chat.example.test/x").slack.value, "https://chat.example.test/x")
    }

    func testLabelWithoutLinkIsHidden() {
        XCTAssertFalse(ContactInfo(slackLabel: "#destek").slack.isAvailable)
        XCTAssertEqual(ContactInfo(slackLabel: "#destek").channels, [])
    }

    func testOnlyHTTPSSlackLinksOpen() {
        for link in ["http://chat.example.test", "file:///etc/passwd", "javascript:alert(1)", "slack://open", "https://", "", "   "] {
            XCTAssertNil(ContactInfo.slackURL(link), link)
        }
        XCTAssertNotNil(ContactInfo.slackURL("  https://chat.example.test  "))
    }

    func testMailAddressCannotCarryParameters() {
        for address in ["a@b", "@example.test", "a@", "a b@example.test", "a@example.test?subject=x",
                        "a@example.test&cc=b@example.test", "a@@example.test", "a@.example.test",
                        "a@example.test.", "a%40b@example.test", "a\n@example.test", ""] {
            XCTAssertNil(ContactInfo.mailURL(address), address.debugDescription)
        }
        XCTAssertEqual(ContactInfo.mailURL(" ad.soyad+dev@example.test ")?.absoluteString, "mailto:ad.soyad+dev@example.test")
    }
}
