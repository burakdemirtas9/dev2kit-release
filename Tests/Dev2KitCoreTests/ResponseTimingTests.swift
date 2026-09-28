import XCTest
@testable import Dev2KitCore

final class ResponseTimingTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// Yeni bağlantı: tüm aşamalar ölçülür.
    private func fullHandshake() -> ResponseTiming? {
        ResponseTiming.make(
            taskStart: start,
            taskEnd: at(0.600),
            fetchStart: start,
            domainLookupStart: at(0.010),
            domainLookupEnd: at(0.020),
            connectStart: at(0.020),
            connectEnd: at(0.300),
            secureConnectionStart: at(0.150),
            secureConnectionEnd: at(0.300),
            requestStart: at(0.300),
            requestEnd: at(0.310),
            responseStart: at(0.580),
            responseEnd: at(0.600),
            isReusedConnection: false
        )
    }

    func testPhasesAreOrderedAndMeasured() throws {
        let timing = try XCTUnwrap(fullHandshake())
        XCTAssertEqual(timing.phases.map(\.kind), [.prepare, .dns, .tcp, .tls, .request, .waiting, .download])
        XCTAssertEqual(timing.total, 0.600, accuracy: 0.001)
    }

    func testTCPStopsWhereTLSStarts() throws {
        // connectEnd TLS'i de kapsıyor; TCP'yi TLS başlangıcında kesmezsek
        // el sıkışma süresi iki kez sayılır.
        let timing = try XCTUnwrap(fullHandshake())
        let tcp = try XCTUnwrap(timing.phases.first { $0.kind == .tcp })
        let tls = try XCTUnwrap(timing.phases.first { $0.kind == .tls })
        XCTAssertEqual(tcp.duration, 0.130, accuracy: 0.001)
        XCTAssertEqual(tls.duration, 0.150, accuracy: 0.001)
        XCTAssertEqual(tcp.start + tcp.duration, tls.start, accuracy: 0.001)
    }

    func testWaitingIsMeasuredFromRequestEndToFirstByte() throws {
        let timing = try XCTUnwrap(fullHandshake())
        let waiting = try XCTUnwrap(timing.phases.first { $0.kind == .waiting })
        XCTAssertEqual(waiting.duration, 0.270, accuracy: 0.001)
    }

    func testSlowestPhaseIsReported() throws {
        let timing = try XCTUnwrap(fullHandshake())
        XCTAssertEqual(timing.slowest?.kind, .waiting)
    }

    func testReusedConnectionHasNoHandshakePhases() throws {
        // Havuzdan gelen bağlantıda DNS/TCP/TLS yaşanmaz; eksik değil, yok.
        let timing = try XCTUnwrap(ResponseTiming.make(
            taskStart: start,
            taskEnd: at(0.150),
            fetchStart: start,
            domainLookupStart: nil, domainLookupEnd: nil,
            connectStart: nil, connectEnd: nil,
            secureConnectionStart: nil, secureConnectionEnd: nil,
            requestStart: at(0.002),
            requestEnd: at(0.003),
            responseStart: at(0.140),
            responseEnd: at(0.150),
            isReusedConnection: true
        ))
        XCTAssertEqual(timing.phases.map(\.kind), [.prepare, .request, .waiting, .download])
        XCTAssertTrue(timing.isReusedConnection)
    }

    func testZeroLengthPhasesAreDropped() throws {
        // Aynı milisaniyede başlayıp biten aşama şeride çizilemez, listeye girmez.
        let timing = try XCTUnwrap(ResponseTiming.make(
            taskStart: start, taskEnd: at(0.100), fetchStart: start,
            domainLookupStart: at(0.010), domainLookupEnd: at(0.010),
            connectStart: nil, connectEnd: nil,
            secureConnectionStart: nil, secureConnectionEnd: nil,
            requestStart: at(0.010), requestEnd: at(0.011),
            responseStart: at(0.090), responseEnd: at(0.100),
            isReusedConnection: true
        ))
        XCTAssertFalse(timing.phases.contains { $0.kind == .dns })
    }

    func testNoMeasurablePhasesReturnsNil() {
        XCTAssertNil(ResponseTiming.make(
            taskStart: start, taskEnd: at(0.1), fetchStart: nil,
            domainLookupStart: nil, domainLookupEnd: nil,
            connectStart: nil, connectEnd: nil,
            secureConnectionStart: nil, secureConnectionEnd: nil,
            requestStart: nil, requestEnd: nil,
            responseStart: nil, responseEnd: nil,
            isReusedConnection: true
        ), "ölçülebilir aşama yoksa boş şelale çizilmemeli")
    }

    func testPhaseStartsAreRelativeToFetchStart() throws {
        let timing = try XCTUnwrap(fullHandshake())
        let dns = try XCTUnwrap(timing.phases.first { $0.kind == .dns })
        let download = try XCTUnwrap(timing.phases.first { $0.kind == .download })
        XCTAssertEqual(dns.start, 0.010, accuracy: 0.001)
        XCTAssertEqual(download.start, 0.580, accuracy: 0.001)
    }

    func testMeasuredSumIsAtMostTotal() throws {
        let timing = try XCTUnwrap(fullHandshake())
        XCTAssertLessThanOrEqual(timing.measured, timing.total + 0.001)
    }
}
