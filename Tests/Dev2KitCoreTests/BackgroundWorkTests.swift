import XCTest
@testable import Dev2KitCore

/// 2026-10-18: Swift eşzamanlılık thread'inde (512 KB yığın) ~500 seviyeli
/// girdi "Sort keys" ve XML → JSON'da uygulamayı çökertiyordu (SIGBUS).
/// Bu testler okuyucuların izin verdiği EN DERİN girdiyi her araçtan geçirir;
/// yardımcı bozulursa test süreci çöker (sessizce geçmez).
final class BackgroundWorkTests: XCTestCase {
    func testRunsOnALargeStack() async {
        let size = await BackgroundWork.run { Thread.current.stackSize }
        XCTAssertEqual(size, BackgroundWork.stackSize)
    }

    /// Okuyucunun kabul ettiği en derin iç içe nesne. Okumak da özyinelemeli:
    /// küçük yığında yapılırsa testin kendisi çöküyordu.
    private static func deepestJSON() -> String? {
        for depth in stride(from: JSONDocument.maxDepth + 1, through: 1, by: -1) {
            let text = String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
            if (try? JSONDocument.parse(text)) != nil { return text }
        }
        return nil
    }

    func testDeepestJSONThroughEveryToolAndDiff() async throws {
        let failures = await BackgroundWork.run { () -> [String] in
            guard let json = Self.deepestJSON() else { return ["derin JSON kurulamadı"] }
            var failures: [String] = []
            let options = WorkbenchOptions(sortKeys: true)
            for tool in WorkbenchCatalog.all where tool.syntax == .json {
                _ = tool.validate?(json)
                for action in tool.actions {
                    do {
                        _ = try action.run(json, options)
                    } catch {
                        // Object Converter derinliği bilerek sınırlar (kullanıcı
                        // kararı): çökmeden, açıklayıcı hatayla reddetmeli.
                        let rejectsDepth = tool.category == .objects
                            && (error as? ObjectCodeGenerator.GenerateError) == .tooDeep(ObjectCodeGenerator.maxDepth)
                        if !rejectsDepth { failures.append("\(tool.id) \(action.id)") }
                    }
                }
            }
            if let value = try? JSONDocument.parse(json) { _ = JSONTreeNode(value: value).children }
            _ = DiffChecker.compare(json, json.replacingOccurrences(of: "1", with: "2"), language: .json)
            return failures
        }
        // JSON → CSV'de sütun adı uzun ama geçerli; hiçbir araç hata vermemeli.
        XCTAssertEqual(failures, [])
    }

    func testDeepestXMLThroughXMLToolsAndDiff() async {
        let depth = JSONDocument.maxDepth
        let xml = String(repeating: "<a>", count: depth) + "1" + String(repeating: "</a>", count: depth)
        let ok = await BackgroundWork.run { () -> Bool in
            for action in WorkbenchTools.xml.actions { _ = try? action.run(xml, .init()) }
            _ = MarkupTools.validateXML(xml)
            _ = DiffChecker.compare(xml, xml, language: .xml)
            return true
        }
        XCTAssertTrue(ok, "en derin XML araçlardan çökmeden geçmeli")
    }
}
