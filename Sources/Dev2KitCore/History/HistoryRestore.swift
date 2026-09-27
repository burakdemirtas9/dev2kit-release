import Foundation

/// Geçmişteki anlık görüntüyü isteğe geri yazma kuralları.
///
/// Neden Core'da: "hangi alan geri yüklenir, hangisi korunur" davranışsal bir
/// karar ve yanlışı sessizce çalışan bir kimlik bilgisini bozar. Maskelenmiş
/// (`••••••`) değerler ASLA geri yazılmaz; o alanlarda isteğin mevcut değeri
/// korunur.
public enum HistoryRestore {
    /// Anlık görüntüyü hedef isteğin üstüne uygular; maskeli alanlar korunur.
    public static func apply(_ snapshot: RequestModel, to target: RequestModel) -> RequestModel {
        var restored = target
        restored.method = snapshot.method
        restored.url = snapshot.url.contains(HistoryRedactor.mask) ? target.url : snapshot.url
        restored.queryParams = merged(snapshot.queryParams, into: target.queryParams)
        restored.headers = merged(snapshot.headers, into: target.headers)
        restored.body = snapshot.body
        restored.options = snapshot.options
        if !containsMask(snapshot.auth) { restored.auth = snapshot.auth }
        return restored
    }

    /// Maskeli değerler isteğin mevcut hâlinden alınır; diğerleri görüntüden gelir.
    /// Aynı ada sahip alan yoksa değer boş bırakılır — maskeyi yazmaktansa boş
    /// bırakmak dürüst davranış.
    public static func merged(_ snapshot: [KeyValueEntry], into current: [KeyValueEntry]) -> [KeyValueEntry] {
        snapshot.map { entry in
            guard entry.value.contains(HistoryRedactor.mask) else { return entry }
            var restored = entry
            restored.value = current.first { $0.key.lowercased() == entry.key.lowercased() }?.value ?? ""
            return restored
        }
    }

    /// Auth yapılandırmasında maskelenmiş bir sır var mı?
    public static func containsMask(_ auth: AuthConfig) -> Bool {
        switch auth {
        case .none: return false
        case .basic(_, let password): return password.contains(HistoryRedactor.mask)
        case .bearer(let token): return token.contains(HistoryRedactor.mask)
        case .apiKey(_, let value, _): return value.contains(HistoryRedactor.mask)
        case .oauth2(let config): return config.clientSecret.contains(HistoryRedactor.mask)
        }
    }
}
