import Foundation

/// Uygulamanın veri dizini.
public enum AppPaths {
    /// Veri dizinini değiştiren ortam değişkeni.
    ///
    /// Neden var: uygulamayı deneme/teşhis amacıyla çalıştırmak kullanıcının
    /// gerçek workspace'ini değiştirme riski taşıyor (bir kere ucuz atlatıldı:
    /// test tıklamaları açık isteğin gövde tipini değiştirdi). Bu değişkenle
    /// uygulama tamamen ayrı bir dizinde açılır; gerçek veri elleşilmez.
    ///
    /// `DEV2KIT_CA_PATH` ile aynı desen.
    public static let directoryEnvironmentKey = "DEV2KIT_DATA_DIR"

    /// Varsayılan: ~/Library/Application Support/dev2kit
    /// `DEV2KIT_DATA_DIR` doluysa o yol kullanılır.
    public static var supportDirectory: URL {
        directory(environment: ProcessInfo.processInfo.environment)
    }

    /// Veri dizini `DEV2KIT_DATA_DIR` ile değiştirildi mi.
    ///
    /// Keychain kullanıcı başına tektir, veri dizini başına değil: deneme
    /// dizininde açılan uygulama gerçek dizinin Keychain anahtarına dokunmasın.
    public static var isOverridden: Bool {
        override(environment: ProcessInfo.processInfo.environment) != nil
    }

    /// Test edilebilmesi için ortam dışarıdan verilebilir.
    static func directory(environment: [String: String]) -> URL {
        if let override = override(environment: environment) {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("dev2kit")
    }

    /// Boş değişken "varsayılanı kullan" demektir.
    static func override(environment: [String: String]) -> String? {
        guard let value = environment[directoryEnvironmentKey],
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
