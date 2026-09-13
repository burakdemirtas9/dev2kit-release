import Foundation

/// Geçmiş kayıtlarını boyut açısından sınırlar.
///
/// Adet ve yaş sınırı tek başına yetmiyor: tek bir kayıt isteğin TÜM gövdesini
/// taşır. 2 MB'lık bir JSON gönderirsen o da kaydedilir; 200 kayıt böyle
/// olursa dosya yüzlerce megabayta çıkar. Üstelik dosya her gönderimde
/// tamamen yeniden yazıldığı için bu, her istekte ödenen bir maliyet olur.
public enum HistoryTrimmer {
    public static let truncationNotice = "\n… (kayıt için kırpıldı)"

    /// Anlık görüntüdeki gövdeyi bayt sınırına indirir.
    /// Neyi gönderdiğini anlamak için gövdenin başı yeterlidir.
    public static func trim(_ model: RequestModel, maxBodyBytes: Int) -> RequestModel {
        guard maxBodyBytes > 0 else { return model }
        var copy = model
        switch model.body {
        case .none:
            break
        case .raw(let content, let contentType):
            copy.body = .raw(content: truncate(content, to: maxBodyBytes), contentType: contentType)
        case .formURLEncoded(let fields):
            copy.body = .formURLEncoded(fields: trim(fields, maxBodyBytes: maxBodyBytes))
        case .multipartForm(let fields):
            copy.body = .multipartForm(fields: trim(fields, maxBodyBytes: maxBodyBytes))
        }
        return copy
    }

    /// Alan başına sınır: tek bir dev alan kaydı şişirmesin.
    private static func trim(_ fields: [KeyValueEntry], maxBodyBytes: Int) -> [KeyValueEntry] {
        let perField = max(256, maxBodyBytes / max(1, fields.count))
        return fields.map { entry in
            var trimmed = entry
            trimmed.value = truncate(entry.value, to: perField)
            return trimmed
        }
    }

    /// UTF-8 bayt sınırına göre kırpar. Çok baytlı karakterin ortasından
    /// kesmemek için gerekirse birkaç bayt geri çekilir.
    public static func truncate(_ text: String, to maxBytes: Int) -> String {
        let utf8 = Array(text.utf8)
        guard utf8.count > maxBytes else { return text }
        var end = maxBytes
        while end > 0 {
            if let prefix = String(bytes: utf8[0..<end], encoding: .utf8) {
                return prefix + truncationNotice
            }
            end -= 1
        }
        return truncationNotice
    }

    /// Toplam bayt bütçesini aşan eski kayıtları düşürür.
    /// Kayıtlar en yeniden eskiye sıralı gelmelidir.
    public static func fitToBudget(_ entries: [HistoryEntry], maxTotalBytes: Int) -> [HistoryEntry] {
        guard maxTotalBytes > 0, !entries.isEmpty else { return entries }
        let encoder = JSONEncoder()
        var kept: [HistoryEntry] = []
        var total = 0
        for entry in entries {
            let size = (try? encoder.encode(entry).count) ?? 0
            // En yeni kayıt tek başına bütçeyi aşsa bile tutulur: aksi halde
            // büyük bir istek geçmişi tamamen boşaltırdı.
            if !kept.isEmpty, total + size > maxTotalBytes { break }
            kept.append(entry)
            total += size
        }
        return kept
    }
}
