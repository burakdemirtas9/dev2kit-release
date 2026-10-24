import Foundation

/// HTTP status kodlarının metni ve status alanındaki kedi görseli eşlemesi.
public enum HTTPStatus {
    /// Standart gerekçe ifadeleri (RFC 9110; 418 RFC 2324). Dil bağımsız,
    /// çevrilmez. Bilinmeyen kodda `nil`.
    public static func reasonPhrase(_ statusCode: Int) -> String? {
        switch statusCode {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 415: return "Unsupported Media Type"
        case 418: return "I'm a teapot"
        case 422: return "Unprocessable Content"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return nil
        }
    }

    /// "404 Not Found"; ifade bilinmiyorsa yalnızca kod.
    public static func summary(_ statusCode: Int) -> String {
        reasonPhrase(statusCode).map { "\(statusCode) \($0)" } ?? String(statusCode)
    }
}

/// Status alanında çift tıklayınca gösterilen kedi görselleri (easter egg).
///
/// Dosyalar `Sources/Dev2KitApp/Resources/HTTPCats/http-cat-<kod>.png`
/// (kaynak seriden 128 px'e küçültüldü). Liste dosya adlarından; testi
/// (`HTTPStatusTests`) klasördeki dosyalarla birebir aynı olduğunu doğrular.
public enum HTTPCats {
    public static let directory = "HTTPCats"

    public static let codes: Set<Int> = [200, 201, 204, 301, 400, 401, 403, 404, 408, 418, 429, 500, 502, 503, 504]

    /// Kodun görselinin kaynak adı (uzantısız); görsel yoksa `nil`.
    public static func resourceName(for statusCode: Int) -> String? {
        codes.contains(statusCode) ? "http-cat-\(statusCode)" : nil
    }
}
