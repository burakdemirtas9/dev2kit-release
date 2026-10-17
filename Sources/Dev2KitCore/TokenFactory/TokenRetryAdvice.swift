import Foundation

/// Token kullanan bir istek hata aldığında kullanıcıya ne önerileceği.
///
/// Akış bilerek otomatik DEĞİL: token'ı yenileyip isteği kendiliğinden
/// yeniden göndermek, POST gibi tekrarlanması güvenli olmayan bir isteği
/// kullanıcının haberi olmadan iki kez çalıştırmak demek. Kullanıcı seçer.
///
/// 1. Token kullanan istek 2xx dışı döndü → "token'ı yenile ve tekrar gönder"
///    önerilir (token sunucuda erken geçersiz kılınmış olabilir).
/// 2. Yenilenmiş token'la yine 2xx dışı döndü → sorun büyük ihtimalle
///    token'ın süresi değil İÇERİĞİ: yanlış müşteri, scope ya da environment.
///    Yeniden yenilemek aynı sonucu verir; kullanıcı token isteğine bakmalı.
public enum TokenRetryAdvice: Equatable, Sendable {
    case offerRefresh(statusCode: Int, variables: [String])
    case checkTokenContent(statusCode: Int, variables: [String])

    /// - Parameters:
    ///   - usedVariables: isteğin kullandığı Token Factory değişkenleri.
    ///   - afterRefresh: bu gönderim kullanıcının "yenile ve tekrar gönder"
    ///     seçimiyle mi yapıldı.
    /// - Returns: öneri yoksa `nil` (başarılı yanıt ya da token kullanmayan istek).
    public static func advice(statusCode: Int, usedVariables: [String], afterRefresh: Bool) -> TokenRetryAdvice? {
        guard !usedVariables.isEmpty, !(200..<300).contains(statusCode) else { return nil }
        let variables = usedVariables.sorted()
        return afterRefresh
            ? .checkTokenContent(statusCode: statusCode, variables: variables)
            : .offerRefresh(statusCode: statusCode, variables: variables)
    }

    public var statusCode: Int {
        switch self {
        case .offerRefresh(let status, _), .checkTokenContent(let status, _): return status
        }
    }

    public var variables: [String] {
        switch self {
        case .offerRefresh(_, let variables), .checkTokenContent(_, let variables): return variables
        }
    }
}
