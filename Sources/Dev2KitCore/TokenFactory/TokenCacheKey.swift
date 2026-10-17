import Foundation

/// Bellekteki bir token'ın HANGİ gönderim için alındığı.
///
/// Kural: token isteğinin gönderilecek hali değişince token düşer. Gönderilecek
/// hal = istek (adı hariç) + yanıt ayarı + isteğin kullandığı environment
/// değerleri. Neden değerler de: aynı environment'ta `{{customerNo}}` 111 → 222
/// yapılınca anahtar aynı kalıyor, 111'in token'ı 222 sanılarak gidiyordu —
/// sunucu 200 döndüğü için hiçbir uyarı da çıkmıyordu.
///
/// Dışarıda kalanlar:
/// - İstek adı: tele çıkmaz; yeniden adlandırmak token sunucusuna istek attırmamalı.
/// - İsteğin kullanmadığı environment değerleri: `pageSize` değişince token kalır.
/// - Vault değerleri (`{{secret:…}}`): anahtara girmesi için vault okunmalı;
///   secret yenilenince eski token süresi bitene kadar aynı client'ın geçerli
///   token'ı olarak kalır, bilerek bırakıldı.
public struct TokenCacheKey: Hashable, Sendable {
    /// Environment yoksa `nil`. Ayrı tutulur: Test'in token'ı Prod'a gitmez.
    public let environmentID: UUID?
    public let requestID: UUID
    /// Adı boşaltılmış istek; `tokenOutput` da içinde (alan değişirse token değişir).
    let request: RequestModel
    /// İsteğin doğrudan ya da başka değişkenler üzerinden kullandığı
    /// environment değişkenleri ve değerleri. Tanımsız olan yer almaz;
    /// sonradan tanımlanırsa anahtar değişir.
    let variables: [String: String]

    public init(source: TokenFactory.Source, environment: EnvironmentModel?) {
        environmentID = environment?.id
        requestID = source.request.id
        var request = source.request
        request.name = ""
        request.tokenOutput = source.output
        self.request = request

        let names = SecretReferences.variableNames(in: source.request, environment: environment)
        var values: [String: String] = [:]
        for entry in environment?.variables ?? [] where entry.enabled && names.contains(entry.key) {
            values[entry.key] = entry.value
        }
        variables = values
    }
}

public extension TokenFactory {
    /// Workspace'in şu anki halinde geçerli olabilecek tüm token anahtarları:
    /// her environment (ve environment'sız durum) için her etkin token isteği.
    ///
    /// Bunun dışında kalan bellekteki token artık hiçbir gönderimde
    /// kullanılamaz (istek/değer değişti, istek ya da environment silindi);
    /// tutulmasının anlamı yok, düşürülür.
    static func liveCacheKeys(in workspace: WorkspaceModel) -> Set<TokenCacheKey> {
        let requests = workspace.tokenFactoryRequests
        guard !requests.isEmpty else { return [] }
        var keys = Set<TokenCacheKey>()
        for environment in [nil] + workspace.environments.map(Optional.some) {
            for source in sources(in: requests, environment: environment) {
                keys.insert(TokenCacheKey(source: source, environment: environment))
            }
        }
        return keys
    }
}
