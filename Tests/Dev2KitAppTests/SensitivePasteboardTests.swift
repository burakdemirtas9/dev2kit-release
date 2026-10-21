import AppKit
import XCTest
@testable import Dev2KitApp

/// Secret taşıyan kopya: yalnızca bu Mac ve pano yöneticilerine "saklama"
/// işareti. Genel panoya dokunulmaz; testte adlandırılmış özel pano.
final class SensitivePasteboardTests: XCTestCase {
    func testSensitiveCopyIsLocalAndConcealed() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev2kit-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        SensitivePasteboard.copy("SYNTHETIC-TOKEN", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "SYNTHETIC-TOKEN")
        XCTAssertTrue(pasteboard.types?.contains(SensitivePasteboard.concealedType) == true)
    }
}
