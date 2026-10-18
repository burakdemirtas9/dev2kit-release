import Foundation

/// Gövde tipi — arayüzdeki seçicinin ve taslak saklamanın ortak dili.
public enum BodyKind: String, CaseIterable, Identifiable, Sendable {
    case none
    case formData
    case urlEncoded
    case raw

    public var id: String { rawValue }
}

public extension RequestBody {
    var kind: BodyKind {
        switch self {
        case .none: return .none
        case .raw: return .raw
        case .formURLEncoded: return .urlEncoded
        case .multipartForm: return .formData
        }
    }

    /// İçerik var mı (editör sekmesindeki "Body" noktası). Yalnızca boşluktan
    /// oluşan raw gövde ya da hiç dolu ve etkin alanı olmayan form gövdesi
    /// içerik sayılmaz: gönderilen istekte fiilen bir şey taşımıyorlar.
    var hasContent: Bool {
        switch self {
        case .none: return false
        case .raw(let content, _): return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .formURLEncoded(let fields), .multipartForm(let fields):
            return fields.contains { $0.enabled && !($0.key.isEmpty && $0.value.isEmpty) }
        }
    }

    /// Tipin boş hali. Raw'ın varsayılanı JSON: en sık yazılan gövde o.
    static func empty(_ kind: BodyKind) -> RequestBody {
        switch kind {
        case .none: return .none
        case .raw: return .raw(content: "", contentType: Beautifier.Kind.json.contentType)
        case .urlEncoded: return .formURLEncoded(fields: [])
        case .formData: return .multipartForm(fields: [])
        }
    }

    // MARK: - Alan erişimi
    //
    // Arayüzdeki her Binding aynı `switch`i tekrar yazıyordu (get'te bir kez,
    // set'te bir kez). Kural tek yerde: gövde tipi uymuyorsa okuma boş döner,
    // yazma sessizce yok sayılır — yanlış tipe yazıp veriyi bozmaktansa.

    var rawContent: String {
        if case .raw(let content, _) = self { return content }
        return ""
    }

    var rawContentType: String {
        if case .raw(_, let type) = self { return type }
        return Beautifier.Kind.json.contentType
    }

    var formFields: [KeyValueEntry] {
        switch self {
        case .formURLEncoded(let fields), .multipartForm(let fields): return fields
        default: return []
        }
    }

    func settingRawContent(_ content: String) -> RequestBody {
        guard case .raw(_, let type) = self else { return self }
        return .raw(content: content, contentType: type)
    }

    func settingRawContentType(_ contentType: String) -> RequestBody {
        guard case .raw(let content, _) = self else { return self }
        return .raw(content: content, contentType: contentType)
    }

    func settingFormFields(_ fields: [KeyValueEntry]) -> RequestBody {
        switch self {
        case .formURLEncoded: return .formURLEncoded(fields: fields)
        case .multipartForm: return .multipartForm(fields: fields)
        default: return self
        }
    }
}

/// Gövde tipi değiştirilirken ayrılan tipin içeriğini saklar.
///
/// Neden: JSON yazıp "Form Data"ya bakıp geri dönen kullanıcı yazdığını
/// kaybetmemeli. Saklama şu an yalnızca istek açıkken yaşıyor (view state);
/// kalıcı hale getirmek istendiğinde kural burada hazır duruyor.
public struct BodyDrafts: Sendable {
    private var saved: [BodyKind: RequestBody] = [:]

    public init() {}

    /// Gövdeyi yeni tipe çevirir: ayrılan tip saklanır, dönülen tipin taslağı
    /// varsa geri gelir, yoksa o tipin boş hali kullanılır.
    public mutating func switching(_ body: RequestBody, to kind: BodyKind) -> RequestBody {
        guard body.kind != kind else { return body }
        saved[body.kind] = body
        return saved[kind] ?? .empty(kind)
    }

    /// Saklanan taslak (test ve gözlem için).
    public func draft(for kind: BodyKind) -> RequestBody? { saved[kind] }
}
