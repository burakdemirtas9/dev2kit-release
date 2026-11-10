import Darwin
import Foundation

/// DNS rebinding koruması (güvenlik incelemesi, 2026-11-07, M1).
///
/// Sunucu yalnızca bu Mac'ten erişilebilir, ama tarayıcıda açık kötü niyetli
/// bir site kendi alan adını 127.0.0.1'e çözdürüp (`evil.test` → 127.0.0.1)
/// Mocker'a "kendi sitesiymiş gibi" istek atabilir ve yanıtı okuyabilir.
/// Tarayıcı bu durumda `Host` başlığına saldırganın alan adını yazar; bu
/// yüzden yalnızca yerel adlarla gelen istek yanıtlanır, gerisi 403 alır.
///
/// İzin verilenler: `localhost`, `*.localhost` (RFC 6761: hep yerelde
/// çözülür, saldırgan yönetemez), 127.0.0.0/8, `::1`. Host'suz istek
/// (HTTP/1.0) kabul edilir: tarayıcı her zaman Host gönderir.
public enum MockHostCheck {
    public static func isAllowed(_ request: MockIncomingRequest) -> Bool {
        if let host = absoluteTargetHost(request.target), !isLocal(host) { return false }
        let hosts = request.headerValues("Host")
        guard hosts.count <= 1 else { return false }
        guard let host = hosts.first else { return true }
        return isLocal(hostName(host))
    }

    /// `localhost:8098` → `localhost`, `[::1]:8098` → `::1`; küçük harf, sondaki nokta atılır.
    static func hostName(_ value: String) -> String {
        var host = value.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("[") {
            if let end = host.firstIndex(of: "]") { host = String(host[host.index(after: host.startIndex)..<end]) }
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    public static func isLocal(_ name: String) -> Bool {
        if name == "localhost" || name.hasSuffix(".localhost") { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, name, &v4) == 1 {
            return UInt32(bigEndian: v4.s_addr) >> 24 == 127
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, name, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
            // ::ffff:127.x.x.x
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF { return bytes[12] == 127 }
        }
        return false
    }

    /// Mutlak biçimli hedefin (`http://host:port/yol`) host'u.
    static func absoluteTargetHost(_ target: String) -> String? {
        let lower = target.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://"), let schemeEnd = target.range(of: "://") else { return nil }
        let rest = target[schemeEnd.upperBound...]
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let withoutUser = authority.split(separator: "@").last.map(String.init) ?? String(authority)
        return hostName(withoutUser)
    }
}
