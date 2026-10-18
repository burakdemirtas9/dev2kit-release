import XCTest
@testable import Dev2KitCore

/// Yapıştırılan XML makinedeki dosyaları ya da ağı okutamamalı (XXE) ve
/// varlık genişlemesiyle belleği şişirememeli. Her saldırı, XML'e dokunan
/// HER yoldan geçirilir: biri ileride okuyucu ayarını değiştirirse burada
/// yakalanır. 2026-10-18'de yerel bir dinleyiciyle de denendi: ağ
/// varlıkları için hiç istek gelmedi. Testte ağ adresleri kapalı bir porta
/// (127.0.0.1:9) gider, internete çıkılmaz.
///
/// Koruma iki katlı (ölçüldü, 2026-10-18): `shouldResolveExternalEntities =
/// false` ve ayrıca Foundation `XMLParser`, delege
/// `parser(_:resolveExternalEntityName:systemID:)` veri döndürmedikçe dış
/// varlığı yüklemiyor — ayar geçici olarak `true` yapıldığında da sızıntı
/// olmadı. Bu yüzden test AYARI değil SONUCU korur: okuyucu değişirse ya da
/// biri varlık çözen bir delege eklerse kırmızıya döner.
final class XMLSecurityTests: XCTestCase {
    private static let marker = "DEV2KIT-GIZLI-ICERIK"
    private var secretURL: URL!

    override func setUpWithError() throws {
        secretURL = FileManager.default.temporaryDirectory.appendingPathComponent("dev2kit-xxe-\(UUID()).txt")
        try Self.marker.write(to: secretURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: secretURL)
    }

    private var attacks: [(name: String, xml: String)] {
        let secret = secretURL.absoluteString
        let closed = "http://127.0.0.1:9"
        return [
            ("dosya varlığı", "<?xml version=\"1.0\"?>\n<!DOCTYPE root [\n  <!ENTITY external SYSTEM \"\(secret)\">\n]>\n<root>\n  <user>&external;</user>\n</root>"),
            ("olmayan dosya", "<!DOCTYPE root [<!ENTITY external SYSTEM \"file:///nonexistent-dev2kit-xxe-test\">]><root><user>&external;</user></root>"),
            ("/etc/passwd", "<!DOCTYPE r [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><r>&x;</r>"),
            ("ağ varlığı", "<!DOCTYPE r [<!ENTITY x SYSTEM \"\(closed)/x\">]><r>&x;</r>"),
            ("parametre varlığı", "<!DOCTYPE r [<!ENTITY % p SYSTEM \"\(secret)\"> %p;]><r>x</r>"),
            ("dış DTD", "<!DOCTYPE r SYSTEM \"\(closed)/dtd\"><r>&leak;</r>"),
            ("XInclude", "<r xmlns:xi=\"http://www.w3.org/2001/XInclude\"><xi:include href=\"\(secret)\" parse=\"text\"/></r>"),
        ]
    }

    /// XML'e dokunan her yol; çıktı metne çevrilir.
    private var paths: [(name: String, run: (String) -> String)] {
        var paths: [(String, (String) -> String)] = [
            ("validateXML", { "\(MarkupTools.validateXML($0))" }),
            ("XMLConverter types", { (try? XMLConverter.toJSON($0, detectTypes: true, indent: " ")) ?? "" }),
            ("MarkupFormatter", { (try? MarkupFormatter.beautify($0, flavor: .xml, indent: " ")) ?? "" }),
            ("Beautifier (API Client)", { (try? Beautifier.beautify($0, as: .xml)) ?? "" }),
            ("Diff Checker", { DiffChecker.compare($0, "<r/>", language: .xml).rows.map { "\($0)" }.joined() }),
        ]
        for tool in WorkbenchCatalog.all where tool.syntax == .xml {
            for action in tool.actions {
                paths.append(("\(tool.id) \(action.id)", { (try? action.run($0, .init())) ?? "" }))
            }
        }
        return paths
    }

    func testExternalEntitiesAndIncludesNeverLeak() {
        let leaks = ["DEV2KIT-GIZLI-ICERIK", "root:", "/bin/"]
        for attack in attacks {
            for path in paths {
                let output = path.run(attack.xml)
                for leak in leaks {
                    XCTAssertFalse(output.contains(leak), "\(attack.name) → \(path.name) sızdırdı: \(leak)")
                }
            }
        }
    }

    func testEntityExpansionBombIsRejectedQuickly() {
        var dtd = #"<!ENTITY l0 "lol">"#
        for level in 1...9 {
            dtd += "<!ENTITY l\(level) \"" + String(repeating: "&l\(level - 1);", count: 10) + "\">"
        }
        let bomb = "<!DOCTYPE a [\(dtd)]><a>&l9;</a>"
        let start = Date()
        for path in paths {
            XCTAssertLessThan(path.run(bomb).utf8.count, 100_000, path.name)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "genişleme reddedilmeli, işlenmemeli")
    }
}
