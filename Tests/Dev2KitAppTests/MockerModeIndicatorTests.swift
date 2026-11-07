import AppKit
import SwiftUI
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// Mod seçicideki Mocker yayın simgesi (kullanıcı kararı, 2026-11-07):
/// çalışıyor yeşil, uygulanmamış değişiklik sarı, başlatılamadı kırmızı
/// (üstü çizili), durunca yok. Genişlik sabit: araç çubuğu zıplamaz.
@MainActor
final class MockerModeIndicatorTests: XCTestCase {
    private var root: URL!
    private var state: MockerState?

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mocker-indicator-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        await state?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func testStateMapsToIndicator() async throws {
        let base = UInt16.random(in: 20_000...39_000)
        let state = MockerState(root: root, ports: [base, base + 1, base + 2])
        self.state = state
        state.addEndpoint()
        XCTAssertEqual(state.modeIndicator, .hidden, "durmuşken simge yok")
        await state.start()
        let port = try XCTUnwrap(state.port)
        XCTAssertEqual(state.modeIndicator, .running(port: port))
        state.endpoints[0].response.status = 201
        XCTAssertEqual(state.modeIndicator, .unapplied(port: port))
        state.applyChanges()
        XCTAssertEqual(state.modeIndicator, .running(port: port))
        await state.stop()
        XCTAssertEqual(state.modeIndicator, .hidden)
    }

    func testIndicatorSymbolsAndTooltips() {
        XCTAssertNil(MockerModeIndicator.hidden.symbolName)
        XCTAssertNil(MockerModeIndicator.hidden.toolTip)
        XCTAssertEqual(MockerModeIndicator.running(port: 8098).symbolName, "antenna.radiowaves.left.and.right")
        XCTAssertEqual(MockerModeIndicator.failed("x").symbolName, "antenna.radiowaves.left.and.right.slash")
        XCTAssertTrue(MockerModeIndicator.running(port: 8098).toolTip?.contains("localhost:8098") == true)
        XCTAssertTrue(MockerModeIndicator.unapplied(port: 8099).toolTip?.contains("localhost:8099") == true)
        XCTAssertEqual(MockerModeIndicator.failed("portlar dolu").toolTip, "portlar dolu")
        for indicator in [MockerModeIndicator.running(port: 1), .unapplied(port: 1), .failed("x")] {
            XCTAssertNotNil(NSImage(systemSymbolName: indicator.symbolName!, accessibilityDescription: nil),
                            "simge sistemde var (macOS 14)")
        }
    }

    func testControlShowsIconKeepsWidthAndRestoresLabel() throws {
        let control = DottedSegmentedControl(labels: AppMode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        control.segmentDistribution = .fillEqually
        control.selectedSegment = 0
        control.frame = NSRect(origin: .zero, size: control.intrinsicContentSize)
        control.layoutSubtreeIfNeeded()
        let mocker = try XCTUnwrap(AppMode.allCases.firstIndex(of: .mocker))
        let width = control.intrinsicContentSize.width
        func icon() -> NSImageView? { control.subviews.compactMap { $0 as? NSImageView }.first }

        control.mockerIndicator = .running(port: 8098)
        control.layoutSubtreeIfNeeded()
        XCTAssertEqual(icon()?.isHidden, false)
        XCTAssertEqual(control.toolTip(forSegment: mocker), MockerModeIndicator.running(port: 8098).toolTip)
        XCTAssertEqual(control.intrinsicContentSize.width, width, accuracy: 0.5, "simge genişliği değiştirmez")
        let segmentWidth = control.bounds.width / CGFloat(control.segmentCount)
        let frame = try XCTUnwrap(icon()?.frame)
        XCTAssertGreaterThan(frame.minX, segmentWidth * CGFloat(mocker), "simge Mocker segmentinde")
        XCTAssertLessThan(frame.maxX, segmentWidth * CGFloat(mocker + 1), "segmentin dışına taşmaz")

        control.mockerIndicator = .hidden
        XCTAssertEqual(icon()?.isHidden, true)
        XCTAssertEqual(control.label(forSegment: mocker), AppMode.mocker.title, "etiket eski haline döner")
        XCTAssertNil(control.toolTip(forSegment: mocker))
    }
}
