import Foundation

/// Yanıtın süresi nerede geçti: DNS, TCP, TLS, bekleme (TTFB), indirme.
///
/// Neden gerekli: "588 ms" tek başına hiçbir şey söylemez. 480 ms'i TTFB ise
/// sunucu düşünüyordur; 280 ms'i TLS el sıkışması ise bağlantı yeniden
/// kullanılmıyordur; 200 ms'i DNS ise çözümleme sorunludur. Üçü üç ayrı iştir.
///
/// Aşamalar `URLSessionTaskTransactionMetrics` tarihlerinden üretilir. Tarih
/// alanlarının hepsi opsiyoneldir: bağlantı havuzdan geldiğinde DNS/TCP/TLS
/// hiç yaşanmaz. Eksik aşama uydurulmaz, listeye hiç girmez.
public struct ResponseTiming: Sendable, Equatable {
    public struct Phase: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, CaseIterable {
            case prepare
            case dns
            case tcp
            case tls
            case request
            case waiting
            case download
        }

        public let kind: Kind
        /// İşin başlangıcından bu yana geçen süre — şeridin nereden başlayacağı.
        public let start: TimeInterval
        public let duration: TimeInterval

        public var id: String { kind.rawValue }

        public init(kind: Kind, start: TimeInterval, duration: TimeInterval) {
            self.kind = kind
            self.start = start
            self.duration = duration
        }
    }

    public let phases: [Phase]
    /// İşin toplam süresi (istek gönderilmeden önceki hazırlık dahil).
    public let total: TimeInterval
    /// Bağlantı havuzdan geldiyse DNS/TCP/TLS aşamaları yoktur; arayüz bunu
    /// "eksik veri" değil "olması gereken" diye göstersin.
    public let isReusedConnection: Bool

    public init(phases: [Phase], total: TimeInterval, isReusedConnection: Bool) {
        self.phases = phases
        self.total = total
        self.isReusedConnection = isReusedConnection
    }

    /// Ölçülemeyen aşamalar hariç, gerçekten bilinen sürelerin toplamı.
    public var measured: TimeInterval {
        phases.reduce(0) { $0 + $1.duration }
    }

    /// En uzun süren aşama — arayüz bunu vurgular, göz oraya gitsin.
    public var slowest: Phase? {
        phases.max { $0.duration < $1.duration }
    }

    /// `URLSessionTaskTransactionMetrics` alanlarından kurar.
    ///
    /// Tarihler ham haliyle alınır; sıralama ve eksik alan kontrolü burada
    /// yapılır ki arayüz tarih aritmetiğiyle uğraşmasın. Hiç ölçülebilir
    /// aşama yoksa `nil` döner — boş bir şelale çizmenin anlamı yok.
    public static func make(
        taskStart: Date,
        taskEnd: Date,
        fetchStart: Date?,
        domainLookupStart: Date?,
        domainLookupEnd: Date?,
        connectStart: Date?,
        connectEnd: Date?,
        secureConnectionStart: Date?,
        secureConnectionEnd: Date?,
        requestStart: Date?,
        requestEnd: Date?,
        responseStart: Date?,
        responseEnd: Date?,
        isReusedConnection: Bool
    ) -> ResponseTiming? {
        let origin = fetchStart ?? taskStart
        let total = max(0, taskEnd.timeIntervalSince(taskStart))

        func phase(_ kind: Phase.Kind, _ from: Date?, _ to: Date?) -> Phase? {
            guard let from, let to else { return nil }
            let duration = to.timeIntervalSince(from)
            guard duration > 0 else { return nil }
            return Phase(kind: kind, start: max(0, from.timeIntervalSince(origin)), duration: duration)
        }

        // TCP el sıkışması: TLS varsa bağlantı süresinin TLS'ten önceki kısmı.
        let tcpEnd = secureConnectionStart ?? connectEnd

        let phases = [
            phase(.prepare, origin, domainLookupStart ?? connectStart ?? requestStart),
            phase(.dns, domainLookupStart, domainLookupEnd),
            phase(.tcp, connectStart, tcpEnd),
            phase(.tls, secureConnectionStart, secureConnectionEnd),
            phase(.request, requestStart, requestEnd),
            phase(.waiting, requestEnd ?? requestStart, responseStart),
            phase(.download, responseStart, responseEnd),
        ].compactMap { $0 }

        guard !phases.isEmpty else { return nil }
        return ResponseTiming(phases: phases, total: total, isReusedConnection: isReusedConnection)
    }
}
