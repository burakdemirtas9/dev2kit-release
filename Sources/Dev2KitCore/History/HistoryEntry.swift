import Foundation

/// Gönderilmiş bir isteğin kaydı.
///
/// `snapshot` isteğin ŞABLON hali (secret'lar çözülmemiş, ham kimlik bilgileri
/// maskelenmiş); geçmiş dosyası ele geçse bile kullanılabilir bir kimlik
/// bilgisi içermez.
public struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Outcome: Codable, Hashable, Sendable {
        case completed(status: Int, duration: TimeInterval, byteCount: Int, redirectCount: Int)
        case failed(message: String)

        public var statusCode: Int? {
            if case .completed(let status, _, _, _) = self { return status }
            return nil
        }

        public var isSuccess: Bool {
            guard let statusCode else { return false }
            return (200..<300).contains(statusCode)
        }
    }

    public let id: UUID
    public let date: Date
    /// İstek sonradan silinmiş olabilir; geri yükleme buna göre davranır.
    public let requestID: UUID?
    public let requestName: String
    public let collectionName: String?
    public let environmentName: String?
    public let method: HTTPMethod
    /// Query'deki kimlik parametreleri maskeli.
    public let url: String
    public let outcome: Outcome
    public let snapshot: RequestModel
    /// Yalnızca ayarlarda açıksa doldurulur; maskeli ve boyutu sınırlı.
    public let responsePreview: String?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        requestID: UUID?,
        requestName: String,
        collectionName: String?,
        environmentName: String?,
        method: HTTPMethod,
        url: String,
        outcome: Outcome,
        snapshot: RequestModel,
        responsePreview: String? = nil
    ) {
        self.id = id
        self.date = date
        self.requestID = requestID
        self.requestName = requestName
        self.collectionName = collectionName
        self.environmentName = environmentName
        self.method = method
        self.url = url
        self.outcome = outcome
        self.snapshot = snapshot
        self.responsePreview = responsePreview
    }
}

/// Geçmiş davranışının ayarları.
public struct HistorySettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    /// Saklanacak en fazla kayıt sayısı.
    public var retentionCount: Int
    /// Bu yaştan eski kayıtlar budanır.
    public var retentionDays: Int
    /// Yanıt gövdesi saklansın mı. Varsayılan AÇIK (kullanıcı kararı,
    /// 2026-10-19; önce kapalıydı). Gövdenin ilk `responsePreviewLimit`
    /// karakteri şifreli geçmiş dosyasına yazılır; kimlik alanları
    /// (token/parola anahtarları) maskelenir, kişisel veri (e-posta, müşteri
    /// numarası) MASKELENMEZ. Kayıtlı ayarı olan kullanıcının tercihi korunur.
    public var storeResponseBodies: Bool
    /// Saklanırsa önizleme karakter sınırı.
    public var responsePreviewLimit: Int
    /// Anlık görüntüdeki istek gövdesi bu bayt sınırına kırpılır.
    /// Adet/yaş sınırı tek başına yetmez: tek bir büyük gövde dosyayı şişirir.
    public var maxSnapshotBodyBytes: Int
    /// Geçmiş dosyasının toplam bayt bütçesi; aşılırsa en eski kayıtlar düşer.
    public var maxTotalBytes: Int

    public static let `default` = HistorySettings()

    public init(
        isEnabled: Bool = true,
        retentionCount: Int = 200,
        retentionDays: Int = 30,
        storeResponseBodies: Bool = true,
        responsePreviewLimit: Int = 20_000,
        maxSnapshotBodyBytes: Int = 32_768,
        maxTotalBytes: Int = 10 * 1024 * 1024
    ) {
        self.isEnabled = isEnabled
        self.retentionCount = max(1, min(retentionCount, 5_000))
        self.retentionDays = max(1, min(retentionDays, 365))
        self.storeResponseBodies = storeResponseBodies
        self.responsePreviewLimit = max(500, min(responsePreviewLimit, 200_000))
        self.maxSnapshotBodyBytes = max(1_024, min(maxSnapshotBodyBytes, 1_048_576))
        self.maxTotalBytes = max(1_048_576, min(maxTotalBytes, 512 * 1024 * 1024))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            retentionCount: try container.decodeIfPresent(Int.self, forKey: .retentionCount) ?? 200,
            retentionDays: try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30,
            storeResponseBodies: try container.decodeIfPresent(Bool.self, forKey: .storeResponseBodies) ?? true,
            responsePreviewLimit: try container.decodeIfPresent(Int.self, forKey: .responsePreviewLimit) ?? 20_000,
            maxSnapshotBodyBytes: try container.decodeIfPresent(Int.self, forKey: .maxSnapshotBodyBytes) ?? 32_768,
            maxTotalBytes: try container.decodeIfPresent(Int.self, forKey: .maxTotalBytes) ?? 10 * 1024 * 1024
        )
    }
}
