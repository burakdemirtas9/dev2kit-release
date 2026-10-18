import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

@MainActor
final class AutoImportAppTests: XCTestCase {
    private func pdf(lines: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 40, y: 740 - index * 18), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    func testCurlInsideAPDFDocumentIsFound() throws {
        let data = pdf(lines: ["API Kılavuzu", "Siparişleri listelemek için:", "curl https://api.example.com/v1/orders -H 'Accept: application/json'", "Teşekkürler."])
        XCTAssertEqual(try ImportFile.kind(of: data).get(), .pdf)
        let text = try AutoImportView.pdfText(data)
        XCTAssertEqual(AutoImport.scan(text).curl.map(\.request.name), ["GET /v1/orders"], text)
    }

    /// Kullanıcı isteği (2026-10-19): belgede koleksiyon ve Kibana kaydı da bulunsun.
    func testKibanaRecordPrintedInsideAPDFIsFound() throws {
        let lines = [
            "Hata raporu", "{", #"  "_index": "test-incoming-log-2026.10.19","#, #"  "_id": "a1","#,
            #"  "_source": {"http_method": "GET", "request_path": "/v1/x", "service_name": "svc"}"#, "}", "Son.",
        ]
        let text = try AutoImportView.pdfText(pdf(lines: lines))
        let found = AutoImport.scan(text)
        XCTAssertEqual(found.kibanaDocuments.count, 1, text)
    }

    func testDocumentWithoutCurlExplainsWhy() throws {
        let text = try AutoImportView.pdfText(pdf(lines: ["Sadece düz bir rapor."]))
        XCTAssertNotNil(AutoImport.scan(text).emptyReason)
    }

    func testFoundRequestsGoThroughTheSecurityReview() {
        let harness = AppStateHarness()
        defer { harness.tearDown() }
        let findings = AutoImport.scan("""
        curl https://api.example.com/v1/me -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl'
        curl https://api.example.com/v1/health
        """).curl
        let prepared = harness.state.prepareCollectionImport(name: "api-docs", requests: findings.map(\.request), notes: [])
        XCTAssertEqual(prepared.review.collection.name, "api-docs")
        XCTAssertEqual(prepared.review.collection.requests.count, 2)
        XCTAssertFalse(prepared.review.isClean, "gömülü token incelemeye takılmalı")

        harness.state.importPrepared(prepared)
        XCTAssertNotNil(harness.state.pendingImport, "temiz değilse doğrudan eklenmez, inceleme açılır")
    }

    func testCleanRequestsAreAddedDirectlyAndNamesDoNotCollide() {
        let harness = AppStateHarness()
        defer { harness.tearDown() }
        let findings = AutoImport.scan("curl https://api.example.com/v1/health").curl
        let first = harness.state.prepareCollectionImport(name: "docs", requests: findings.map(\.request), notes: [])
        harness.state.importPrepared(first)
        let second = harness.state.prepareCollectionImport(name: "docs", requests: findings.map(\.request), notes: [])
        XCTAssertNotEqual(second.review.collection.name, "docs")
        XCTAssertTrue(second.wasRenamed)
    }
}

/// 2026-10-19: otomatik içe aktarma Kibana kaydını tanıyıp ekranını açtı ama
/// JSON gelmedi, kullanıcı yeniden yapıştırmak zorunda kaldı.
@MainActor
final class ImportPrefillTests: XCTestCase {
    private func editorText(_ view: some View, harness: AppStateHarness) -> String? {
        let host = NSHostingView(rootView: view.environment(harness.state))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        func editors(_ v: NSView) -> [NSTextView] { (v as? NSTextView).map { [$0] } ?? v.subviews.flatMap(editors) }
        return editors(host).first { !$0.string.isEmpty }?.string
    }

    func testKibanaScreenOpensWithTheDetectedLog() {
        let harness = AppStateHarness()
        defer { harness.tearDown() }
        let log = #"{"_index": "test-incoming-log-2026.10.19", "_source": {"http_method": "GET", "request_path": "/v1/x", "service_name": "svc"}}"#
        XCTAssertEqual(editorText(KibanaImportView(initialJSON: log), harness: harness), log)
    }

    func testOpenAPIScreenOpensWithTheDetectedDocument() {
        let harness = AppStateHarness()
        defer { harness.tearDown() }
        let doc = #"{"openapi": "3.0.1", "info": {"title": "T", "version": "1"}, "paths": {}}"#
        XCTAssertEqual(editorText(OpenAPIImportView(initialJSON: doc), harness: harness), doc)
    }
}
