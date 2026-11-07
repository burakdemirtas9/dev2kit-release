import Foundation

/// Bağlantıdan parça parça gelen baytlardan HTTP/1.x isteği çıkarır.
///
/// Durumlu: başlık bulunduktan sonra yeniden taranmaz, chunked gövde kaldığı
/// yerden çözülür (büyük gövdede kare büyüme yok). Aynı bağlantıda art arda
/// gelen istekler (keep-alive, pipelining) sırayla çıkar.
/// Sınırlar `MockerLimits`: başlık bölümü 64 KB (aşan 431), gövde 10 MB (413).
public struct MockHTTPReader: Sendable {
    public enum Event: Sendable {
        case needMore
        /// İstemci `Expect: 100-continue` ile gövdeyi bekletiyor: "100 Continue" gönderilmeli.
        case continueExpected
        case request(MockIncomingRequest, keepAlive: Bool)
        /// Bozuk ya da sınırı aşan istek: bu durumla yanıt verilip bağlantı kapanır.
        case failure(status: Int)
    }

    private enum BodyMode: Sendable {
        case none
        case length(Int)
        case chunked
    }

    private struct Head: Sendable {
        let method: String
        let target: String
        let headers: [MockHeader]
        let body: BodyMode
        let keepAlive: Bool
    }

    private var buffer: [UInt8] = []
    /// Başlık sonu aranırken taranmış bayt sayısı (yeniden taranmaz).
    private var scanned = 0
    private var head: Head?
    private var chunkedBody: [UInt8] = []
    private var continueAnswered = false
    private let maxHeadBytes: Int
    private let maxBodyBytes: Int

    public init(maxHeadBytes: Int = MockerLimits.maxRequestHeadBytes, maxBodyBytes: Int = MockerLimits.maxRequestBodyBytes) {
        self.maxHeadBytes = maxHeadBytes
        self.maxBodyBytes = maxBodyBytes
    }

    public mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    /// Bir sonraki olay; `.needMore` dönene kadar çağrılır.
    public mutating func next() -> Event {
        if head == nil {
            guard let end = findHeadEnd() else {
                return buffer.count > maxHeadBytes ? .failure(status: 431) : .needMore
            }
            guard end <= maxHeadBytes else { return .failure(status: 431) }
            switch parseHead(Array(buffer[0..<end])) {
            case .success(let parsed):
                head = parsed
                buffer.removeFirst(end + 4)
                scanned = 0
                chunkedBody = []
                continueAnswered = false
                if case .length(let length) = parsed.body, length > maxBodyBytes { return .failure(status: 413) }
                if expectsContinue(parsed), buffer.isEmpty {
                    continueAnswered = true
                    return .continueExpected
                }
            case .failure(let status):
                return .failure(status: status)
            }
        }
        guard let current = head else { return .needMore }
        switch current.body {
        case .none:
            return finish(current, body: [])
        case .length(let length):
            guard buffer.count >= length else { return .needMore }
            let body = Array(buffer[0..<length])
            buffer.removeFirst(length)
            return finish(current, body: body)
        case .chunked:
            return decodeChunks(current)
        }
    }

    private func expectsContinue(_ head: Head) -> Bool {
        guard !continueAnswered else { return false }
        if case .none = head.body { return false }
        return head.headers.contains {
            $0.name.caseInsensitiveCompare("Expect") == .orderedSame && $0.value.lowercased().contains("100-continue")
        }
    }

    private mutating func finish(_ current: Head, body: [UInt8]) -> Event {
        head = nil
        let request = MockIncomingRequest(method: current.method, target: current.target, headers: current.headers, body: Data(body))
        return .request(request, keepAlive: current.keepAlive)
    }

    private mutating func findHeadEnd() -> Int? {
        let limit = buffer.count
        guard limit >= 4 else { return nil }
        var index = max(0, scanned - 3)
        while index + 3 < limit {
            if buffer[index] == 13, buffer[index + 1] == 10, buffer[index + 2] == 13, buffer[index + 3] == 10 {
                return index
            }
            index += 1
        }
        scanned = limit
        return nil
    }

    private enum HeadResult {
        case success(Head)
        case failure(Int)
    }

    private func parseHead(_ bytes: [UInt8]) -> HeadResult {
        let text = String(decoding: bytes, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        // İstek satırından önce gelen boş satırlar yoksayılır (RFC 9112 §2.2).
        while lines.first?.isEmpty == true { lines.removeFirst() }
        guard let requestLine = lines.first else { return .failure(400) }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."),
              parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) else { return .failure(400) }
        let method = parts[0].uppercased()
        let target = String(parts[1])
        guard target.hasPrefix("/") || target.hasPrefix("http://") || target.hasPrefix("https://") || target == "*" else {
            return .failure(400)
        }
        var headers: [MockHeader] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .failure(400) }
            let name = String(line[..<colon])
            guard !name.isEmpty, name.allSatisfy(MockHTTPWriter.isTokenCharacter) else { return .failure(400) }
            headers.append(MockHeader(name: name, value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        func values(_ name: String) -> [String] {
            headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map { $0.value.lowercased() }
        }
        let body: BodyMode
        if values("Transfer-Encoding").contains(where: { $0.contains("chunked") }) {
            body = .chunked
        } else if case let lengths = values("Content-Length"), !lengths.isEmpty {
            let distinct = Set(lengths.flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } })
            guard distinct.count == 1, let first = distinct.first, let length = Int(first), length >= 0 else { return .failure(400) }
            body = length == 0 ? .none : .length(length)
        } else {
            body = .none
        }
        let connection = values("Connection").joined(separator: ",")
        let keepAlive = parts[2] == "HTTP/1.0" ? connection.contains("keep-alive") : !connection.contains("close")
        return .success(Head(method: method, target: target, headers: headers, body: body, keepAlive: keepAlive))
    }

    /// Chunked gövde: `boyut;uzantı\r\n veri\r\n … 0\r\n (trailer)\r\n`.
    private mutating func decodeChunks(_ current: Head) -> Event {
        while true {
            guard let lineEnd = crlf(from: 0) else {
                return buffer.count > 1_024 ? .failure(status: 400) : .needMore
            }
            let sizeText = String(decoding: buffer[0..<lineEnd], as: UTF8.self)
                .split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !sizeText.isEmpty, sizeText.count <= 8, let size = Int(sizeText, radix: 16) else { return .failure(status: 400) }
            if size == 0 {
                // Trailer'lar boş satıra kadar okunur ve atılır.
                var position = lineEnd + 2
                while true {
                    guard let end = crlf(from: position) else {
                        return buffer.count - position > maxHeadBytes ? .failure(status: 431) : .needMore
                    }
                    if end == position {
                        buffer.removeFirst(end + 2)
                        let body = chunkedBody
                        chunkedBody = []
                        return finish(current, body: body)
                    }
                    position = end + 2
                }
            }
            guard chunkedBody.count + size <= maxBodyBytes else { return .failure(status: 413) }
            let dataStart = lineEnd + 2
            guard buffer.count >= dataStart + size + 2 else { return .needMore }
            guard buffer[dataStart + size] == 13, buffer[dataStart + size + 1] == 10 else { return .failure(status: 400) }
            chunkedBody.append(contentsOf: buffer[dataStart..<(dataStart + size)])
            buffer.removeFirst(dataStart + size + 2)
        }
    }

    private func crlf(from start: Int) -> Int? {
        var index = start
        while index + 1 < buffer.count {
            if buffer[index] == 13, buffer[index + 1] == 10 { return index }
            index += 1
        }
        return nil
    }
}

/// Response'u HTTP/1.1 baytlarına çevirir.
///
/// Header adı ve değeri temizlenir: geçersiz ad atlanır, değerdeki CR/LF
/// boşluk olur (tanımdaki bir değer yanıta başlık enjekte edemez).
/// Content-Length, Transfer-Encoding ve Connection sunucunundur; tanımdakiler
/// yoksayılır. Content-Type verilmemişse gövdeye bakılarak eklenir.
public enum MockHTTPWriter {
    public static let continueResponse = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
    static let managedHeaders: Set<String> = ["content-length", "transfer-encoding", "connection", "keep-alive"]

    public static func data(for response: MockResponse, method: String, keepAlive: Bool) -> Data {
        let status = MockerLimits.statusRange.contains(response.status) ? response.status : 200
        let body = Data(response.body.utf8)
        let allowsBody = status != 204 && status != 304
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        var hasContentType = false
        for entry in response.headers where entry.enabled {
            let name = entry.key.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy(isTokenCharacter), !managedHeaders.contains(name.lowercased()) else { continue }
            if name.lowercased() == "content-type" { hasContentType = true }
            head += "\(name): \(sanitized(entry.value))\r\n"
        }
        if allowsBody, !hasContentType, !body.isEmpty {
            head += "Content-Type: \(guessedContentType(response.body))\r\n"
        }
        if allowsBody { head += "Content-Length: \(body.count)\r\n" }
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var data = Data(head.utf8)
        if allowsBody, method.uppercased() != "HEAD" { data.append(body) }
        return data
    }

    /// Bozuk istek, sınır aşımı: kısa düz metinli yanıt, bağlantı kapanır.
    public static func error(_ status: Int) -> Data {
        let body = "\(status) \(reason(status))\n"
        return Data("HTTP/1.1 \(status) \(reason(status))\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
    }

    /// Skaler düzeyinde: Swift'te "\r\n" TEK karakterdir, karakter karşılaştırması
    /// onu kaçırıyordu (testle yakalandı, 2026-11-07).
    static func sanitized(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            scalars.append(scalar == "\r" || scalar == "\n" || scalar == "\0" ? " " : scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    static func guessedContentType(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return "application/json; charset=utf-8" }
        if trimmed.hasPrefix("<") { return trimmed.lowercased().hasPrefix("<!doctype html") || trimmed.lowercased().hasPrefix("<html")
            ? "text/html; charset=utf-8" : "application/xml; charset=utf-8" }
        return "text/plain; charset=utf-8"
    }

    /// RFC 9110 `tchar`.
    static func isTokenCharacter(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue, ascii > 32, ascii < 127 else { return false }
        return character.isLetter || character.isNumber || "!#$%&'*+-.^_`|~".contains(character)
    }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 413: return "Content Too Large"
        case 415: return "Unsupported Media Type"
        case 422: return "Unprocessable Content"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default:
            switch status {
            case 200..<300: return "OK"
            case 300..<400: return "Redirect"
            case 400..<500: return "Client Error"
            default: return "Server Error"
            }
        }
    }
}
