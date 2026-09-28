import Foundation

/// Yanıttaki izleme (correlation/trace) kimliği.
///
/// Neden: kurumsal bir gateway'in arkasında bir isteğin akıbetini aramak için
/// log sistemine (Kibana) bu kimlikle gidilir. Yanıtın içinden elle kopyalamak
/// yerine arayüz tek tıkla verir.
///
/// Arama sırası bilinçli: daha özel olan başlık daha genel olana tercih edilir.
/// `x-correlation-id` varken `x-request-id` gösterilmez — ikisi farklı şeyler
/// olabilir ve kullanıcı genelde ilkini arar.
public enum CorrelationID {
    /// Sırayla aranan başlıklar. Küçük harfle karşılaştırılır.
    public static let headerNames = [
        "x-correlation-id",
        "correlation-id",
        "x-request-id",
        "request-id",
        "x-b3-traceid",
        "traceparent",
        "x-amzn-trace-id",
        "x-trace-id",
    ]

    public struct Match: Sendable, Equatable {
        /// Başlığın yanıttaki hali (kullanıcı hangi başlıktan geldiğini görsün).
        public let headerName: String
        /// Gösterilecek/kopyalanacak değer.
        public let value: String

        public init(headerName: String, value: String) {
            self.headerName = headerName
            self.value = value
        }
    }

    public static func find(in headers: [(name: String, value: String)]) -> Match? {
        for candidate in headerNames {
            guard let header = headers.first(where: { $0.name.lowercased() == candidate }) else { continue }
            let value = extractedValue(from: header.value, headerName: candidate)
            guard !value.isEmpty else { continue }
            return Match(headerName: header.name, value: value)
        }
        return nil
    }

    /// `traceparent` W3C biçimi: `00-<trace-id>-<span-id>-<flags>`.
    /// Aranan kısım trace-id; tamamını kopyalamak log aramasında işe yaramaz.
    /// Diğer başlıklarda değer olduğu gibi alınır.
    static func extractedValue(from raw: String, headerName: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard headerName == "traceparent" else { return trimmed }
        let parts = trimmed.split(separator: "-")
        guard parts.count >= 2 else { return trimmed }
        return String(parts[1])
    }

    /// Uzun kimlikler arayüzü taşırmasın: baş ve son korunur.
    public static func shortened(_ value: String, limit: Int = 14) -> String {
        guard value.count > limit else { return value }
        let head = value.prefix(6)
        let tail = value.suffix(4)
        return "\(head)…\(tail)"
    }
}
