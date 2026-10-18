import Foundation

/// Ağır, iç içe yapıda özyinelemeli işleri büyük yığınlı bir thread'de koşar.
///
/// Neden `Task.detached` değil: Swift eşzamanlılık thread'lerinin yığını
/// 512 KB. Ağaç yapısında seviye başına yığına çerçeve ekleyen kod (sıralı
/// JSON yazımı, XML → JSON) ~500 seviyede yığını taşırıp uygulamayı
/// ÇÖKERTİYORDU (SIGBUS); okuyucular 512 seviyeye izin veriyor. Ölçüm (M4,
/// release, 2026-10-18): 400 seviye sorunsuz, ~500 çöküş. 16 MB, izin verilen
/// en derin girdinin (512) gereksiniminin onlarca katı; thread kısa ömürlü,
/// bellek iş bitince geri verilir. Thread açmanın maliyeti mikro saniyeler.
///
/// İptal yok: çağıranlar sonucu nesil sayacıyla eler (UI-KURALLARI §4b).
public enum BackgroundWork {
    public static let stackSize = 16 * 1024 * 1024

    public static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: work()) }
            thread.stackSize = stackSize
            thread.qualityOfService = .userInitiated
            thread.name = "dev2kit.background-work"
            thread.start()
        }
    }
}
