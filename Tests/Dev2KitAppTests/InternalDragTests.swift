import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Dev2KitApp

/// Kullanıcı bildirimi (2026-10-31): sekme bir metin alanının üzerine
/// bırakılınca kimliği (UUID) alana yazılıyordu. Yük artık metin değil.
final class InternalDragTests: XCTestCase {
    func testPayloadIsNotTextSoTextFieldsIgnoreIt() {
        let provider = InternalDrag.provider(for: UUID())
        XCTAssertFalse(provider.canLoadObject(ofClass: NSString.self), "metin alanı bunu yazı olarak alamaz")
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.text.identifier))
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier))
        XCTAssertEqual(provider.registeredTypeIdentifiers, [InternalDrag.type.identifier])
    }

    func testOwnDropTargetsReadTheID() async {
        let id = UUID()
        let loaded = await InternalDrag.loadID(from: InternalDrag.provider(for: id))
        XCTAssertEqual(loaded, id)
    }

    /// Başka bir kaynaktan gelen metin (ör. başka uygulama) kimlik sayılmaz.
    func testPlainTextIsNotAcceptedAsAnID() async {
        let text = NSItemProvider(object: UUID().uuidString as NSString)
        let loaded = await InternalDrag.loadID(from: text)
        XCTAssertNil(loaded)
    }
}
