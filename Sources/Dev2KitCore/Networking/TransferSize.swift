import Foundation

/// İstek ve yanıtın tel üzerindeki boyutu, başlık/gövde ayrımıyla.
///
/// Neden ayrım: "666 B" gövdenin boyutu değil, başlıklar da sayılır. Bir
/// isteğin 254 byte'ının 251'i başlıksa sorun gövdede değil, taşıdığın
/// başlıklardadır (çerez yığını, uzun token'lar). Gateway arkasında bu ayrım
/// sık sorulan bir soru.
///
/// Sayılar `URLSessionTaskMetrics`'ten gelir ve TEL ÜZERİNDEKİ byte'lardır.
/// Gövde sıkıştırılmışsa açılmış hali ayrıca tutulur; ikisi arasındaki fark
/// sıkıştırmanın kazancıdır.
public struct TransferSize: Sendable, Equatable {
    public var requestHeaders: Int64
    public var requestBody: Int64
    public var responseHeaders: Int64
    /// Tel üzerinde gelen gövde (sıkıştırılmışsa sıkıştırılmış hali).
    public var responseBody: Int64
    /// Açılmış gövde. Sıkıştırma yoksa `responseBody` ile aynıdır.
    public var responseBodyDecoded: Int64

    public init(
        requestHeaders: Int64 = 0,
        requestBody: Int64 = 0,
        responseHeaders: Int64 = 0,
        responseBody: Int64 = 0,
        responseBodyDecoded: Int64 = 0
    ) {
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.responseBodyDecoded = responseBodyDecoded
    }

    public var requestTotal: Int64 { requestHeaders + requestBody }
    public var responseTotal: Int64 { responseHeaders + responseBody }

    /// Hiçbir şey ölçülmediyse arayüz panoyu hiç açmaz.
    public var isEmpty: Bool { self == TransferSize() }

    /// Sıkıştırma gerçekten kazandırdıysa oran (0,72 = %72 küçülmüş).
    /// Sıkıştırma yoksa ya da ölçülemediyse nil — "%0 kazanç" yazmak yanıltıcı.
    public var compressionRatio: Double? {
        guard responseBody > 0, responseBodyDecoded > responseBody else { return nil }
        return 1 - (Double(responseBody) / Double(responseBodyDecoded))
    }

    /// Yönlendirme varsa her adım ayrı bir işlem; toplamı gerçekte ne kadar
    /// veri gidip geldiğini gösterir.
    public static func + (lhs: TransferSize, rhs: TransferSize) -> TransferSize {
        TransferSize(
            requestHeaders: lhs.requestHeaders + rhs.requestHeaders,
            requestBody: lhs.requestBody + rhs.requestBody,
            responseHeaders: lhs.responseHeaders + rhs.responseHeaders,
            responseBody: lhs.responseBody + rhs.responseBody,
            responseBodyDecoded: lhs.responseBodyDecoded + rhs.responseBodyDecoded
        )
    }
}
