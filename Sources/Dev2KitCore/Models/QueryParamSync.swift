import Foundation

/// Adres çubuğu ile Params tablosunun eşitlenmesi (Postman gibi; kullanıcı
/// isteği, 2026-10-19): tabloya `name=xyz` yazılınca adres `?name=xyz` olur,
/// adrese yazılan sorgu tabloya düşer. Sıra korunur.
///
/// - Adreste yalnızca AÇIK ve adı dolu satırlar görünür. Kapalı satırlar ve
///   adı henüz yazılmamış satırlar tabloda kalır (adresten tabloya eşitleme
///   onları silmez: yazılmakta olan satır kaybolmasın).
/// - Metin ham tutulur (`{{değişken}}` olduğu gibi); boşluk, `ş` gibi
///   karakterleri gönderirken URLComponents kodluyor (macOS 14+, ölçüldü).
///   Yalnızca sorguyu bölen `&`, `#` (ve adda `=`) kodlanır, okurken çözülür.
public enum QueryParamSync {
    public struct Pair: Equatable, Sendable {
        public let key: String
        public let value: String
    }

    /// Adresin sorgu kısmı; adı boş parçalar atlanır.
    public static func pairs(in url: String) -> [Pair] {
        guard let query = parts(of: url).query, !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: true).compactMap { segment in
            let piece = String(segment)
            let key: String, value: String
            if let equals = piece.firstIndex(of: "=") {
                key = String(piece[..<equals])
                value = String(piece[piece.index(after: equals)...])
            } else {
                key = piece
                value = ""
            }
            guard !key.isEmpty else { return nil }
            return Pair(key: decode(key), value: decode(value))
        }
    }

    /// Tablodaki açık satırlarla yeniden yazılmış adres (fragment korunur).
    public static func url(_ url: String, with params: [KeyValueEntry]) -> String {
        let (base, _, fragment) = parts(of: url)
        let query = params
            .filter { $0.enabled && !$0.key.isEmpty }
            .map { encode($0.key, isKey: true) + "=" + encode($0.value, isKey: false) }
            .joined(separator: "&")
        return base + (query.isEmpty ? "" : "?" + query) + (fragment.map { "#" + $0 } ?? "")
    }

    /// Adresten tabloya: açık ve adı dolu satırlar adresteki sırayla
    /// güncellenir (kimlikleri korunur: yazarken odak kaybolmasın), fazlası
    /// silinir, yenileri sona eklenir. Kapalı/adsız satırlar yerinde kalır.
    public static func params(fromURL url: String, current: [KeyValueEntry]) -> [KeyValueEntry] {
        let pairs = pairs(in: url)
        var result: [KeyValueEntry] = []
        var next = 0
        for entry in current {
            guard entry.enabled, !entry.key.isEmpty else {
                result.append(entry)
                continue
            }
            guard next < pairs.count else { continue }
            var updated = entry
            updated.key = pairs[next].key
            updated.value = pairs[next].value
            result.append(updated)
            next += 1
        }
        for pair in pairs[next...] {
            result.append(KeyValueEntry(key: pair.key, value: pair.value))
        }
        return result
    }

    /// Gönderirken: tablodaki açık satırlardan adreste ZATEN olmayanlar.
    /// Eşitlenmiş istekte boş döner (parametre iki kez gitmez); parametresi
    /// yalnızca tabloda olan eski kayıtlarda eskisi gibi hepsi eklenir.
    public static func unrepresented(url: String, params: [KeyValueEntry]) -> [KeyValueEntry] {
        var available = pairs(in: url)
        return params.filter { entry in
            guard entry.enabled, !entry.key.isEmpty else { return false }
            if let index = available.firstIndex(of: Pair(key: entry.key, value: entry.value)) {
                available.remove(at: index)
                return false
            }
            return true
        }
    }

    // MARK: Kullanıcı düzenlemesi sonrası (yazma durunca)
    //
    // Eşitleme yalnızca kullanıcının YAZDIĞI değişiklikle tetiklenir, istek
    // değiştirmekle değil: eski kayıtta (parametre yalnızca tabloda, adreste
    // sorgu yok) adresten tabloya eşitleme parametreleri silerdi. Eski
    // kayıtların "yalnızca adreste" ya da "yalnızca tabloda" duran
    // parametreleri ilk düzenlemede KAYBOLMADAN birleşir.

    public struct Synced: Equatable {
        public let url: String
        public let params: [KeyValueEntry]
    }

    /// Tabloya yazıldı. `paramsBefore`: yazmaya başlamadan önceki tablo.
    /// Adreste olup o tabloda olmayan (eski kayıt) parametreler tabloya alınır.
    public static func afterParamsEdit(url: String, paramsBefore: [KeyValueEntry], params: [KeyValueEntry]) -> Synced {
        var represented = paramsBefore.filter { $0.enabled && !$0.key.isEmpty }.map { Pair(key: $0.key, value: $0.value) }
        var urlOnly: [KeyValueEntry] = []
        for pair in pairs(in: url) {
            if let index = represented.firstIndex(of: pair) {
                represented.remove(at: index)
            } else {
                urlOnly.append(KeyValueEntry(key: pair.key, value: pair.value))
            }
        }
        let merged = urlOnly + params
        return Synced(url: Self.url(url, with: merged), params: merged)
    }

    /// Adrese yazıldı. `urlBefore`: yazmaya başlamadan önceki adres. Sorgu
    /// değişmediyse (ör. yalnız sunucu) tabloya dokunulmaz; değiştiyse tablo
    /// adrese göre güncellenir, yalnızca tabloda duran eski parametreler
    /// korunup adrese de yazılır.
    public static func afterURLEdit(urlBefore: String, url: String, params: [KeyValueEntry]) -> Synced {
        guard pairs(in: urlBefore) != pairs(in: url) else { return Synced(url: url, params: params) }
        let hidden = unrepresented(url: urlBefore, params: params)
        let hiddenIDs = Set(hidden.map(\.id))
        let synced = Self.params(fromURL: url, current: params.filter { !hiddenIDs.contains($0.id) }) + hidden
        return Synced(url: hidden.isEmpty ? url : Self.url(url, with: synced), params: synced)
    }

    // MARK: İç işler

    private static func parts(of url: String) -> (base: String, query: String?, fragment: String?) {
        var rest = url
        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = String(rest[..<hash])
        }
        guard let question = rest.firstIndex(of: "?") else { return (rest, nil, fragment) }
        return (String(rest[..<question]), String(rest[rest.index(after: question)...]), fragment)
    }

    private static func encode(_ text: String, isKey: Bool) -> String {
        var out = text.replacingOccurrences(of: "&", with: "%26").replacingOccurrences(of: "#", with: "%23")
        if isKey { out = out.replacingOccurrences(of: "=", with: "%3D") }
        return out
    }

    private static func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "%26", with: "&")
            .replacingOccurrences(of: "%23", with: "#")
            .replacingOccurrences(of: "%3D", with: "=")
    }
}
