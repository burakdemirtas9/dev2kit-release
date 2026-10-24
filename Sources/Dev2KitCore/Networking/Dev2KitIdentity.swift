import Foundation

/// dev2kit'in kimliği: sürüm ve her istekte giden User-Agent.
///
/// User-Agent SABİT ve kullanıcı EZEMEZ (kullanıcı kararı, 2026-10-18/19):
/// - İz sürme: dev2kit'ten giden test istekleri sunucu loglarında (Kibana)
///   gerçek uygulama/müşteri trafiğinden ayırt edilebilsin.
/// - Politika: araç, mobil uygulama ya da tarayıcı kimliğine bürünüp
///   User-Agent'a dayalı denetimleri atlatmak için kullanılmasın.
/// Kullanıcının User-Agent başlığı yok sayılır; arayüz bunu satırda söyler.
public enum Dev2KitIdentity {
    /// Sürüm (kullanıcı tanımı, 2026-10-19): ilk büyük iş v1 → "1", v2 → "2",
    /// v2 içindeki konum → "0". Arada elle güncellenir; `.app`'in sürümü de
    /// buradan okunur (scripts/make-app.sh).
    public static let version = "1.2"
    /// Derleme numarası (`CFBundleVersion`). Elle, sürümle birlikte artırılır:
    /// eskiden commit sayısından türetiliyordu; tek commit'lik release
    /// deposunda "1" çıkardı (2026-10-25, release 1.2 (177)).
    public static let build = "177"
    public static let userAgent = "dev2kit-v\(version)"
    public static let userAgentHeader = "User-Agent"

    public static func isUserAgent(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(userAgentHeader) == .orderedSame
    }

    /// İsteğe dev2kit User-Agent'ı yazılır (önceki değer ne olursa olsun).
    public static func stamp(_ request: inout URLRequest) {
        request.setValue(userAgent, forHTTPHeaderField: userAgentHeader)
    }
}
