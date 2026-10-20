import Foundation
import Observation

/// Arayüz dili (kullanıcı isteği, 2026-10-20: Türkçe / English).
public enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case turkish = "tr"
    case english = "en"

    public var id: String { rawValue }

    /// Seçicide kendi dilinde: "Türkçe", "English".
    public var displayName: String {
        switch self {
        case .turkish: return "Türkçe"
        case .english: return "English"
        }
    }

    /// Sayı ve tarih biçimi için.
    public var locale: Locale { Locale(identifier: self == .turkish ? "tr_TR" : "en_US") }

    /// İlk açılış: sistem dili Türkçeyse Türkçe, değilse İngilizce.
    public static func systemDefault(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        preferredLanguages.first?.lowercased().hasPrefix("tr") == true ? .turkish : .english
    }
}

/// Seçili dil. Gözlemlenebilir: SwiftUI gövdesi `L10n` üzerinden okuduğunda
/// dil değişince görünüm kendiliğinden yeniden çizilir (yeniden başlatma yok).
///
/// İş parçacığı güvenli: Workbench gibi arka planda çalışan Core kodu da
/// mesaj üretirken okur; değer kilitle korunur, gözlem kaydı elle yapılır.
public final class Localizer: Observable, @unchecked Sendable {
    public static let shared = Localizer()
    /// Tercih anahtarı (UserDefaults).
    public static let defaultsKey = "appLanguage"
    /// Dili kayıtlı tercihten bağımsız sabitleyen ortam değişkeni ("tr" / "en").
    /// `DEV2KIT_DATA_DIR` ile aynı desen: deneme, teşhis ve testi makinenin
    /// diline bağlı olmaktan kurtarmak için.
    public static let environmentKey = "DEV2KIT_LANGUAGE"

    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var storedLanguage: AppLanguage

    init(
        language: AppLanguage? = nil,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        if let language {
            storedLanguage = language
        } else if let raw = environment[Self.environmentKey], let forced = AppLanguage(rawValue: raw.lowercased()) {
            storedLanguage = forced
        } else if let raw = defaults.string(forKey: Self.defaultsKey), let saved = AppLanguage(rawValue: raw) {
            storedLanguage = saved
        } else {
            storedLanguage = AppLanguage.systemDefault()
        }
    }

    public var language: AppLanguage {
        get {
            registrar.access(self, keyPath: \.language)
            lock.lock(); defer { lock.unlock() }
            return storedLanguage
        }
        set {
            registrar.withMutation(of: self, keyPath: \.language) {
                lock.lock(); storedLanguage = newValue; lock.unlock()
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultsKey)
        }
    }
}

/// Merkezi çeviri erişimi. Metinler `L10nTable`'da, anahtar başına Türkçe ve
/// İngilizce yan yana (eksik çeviri incelemede görünür, test yakalar).
///
/// Kurallar (docs/LOCALIZATION.md):
/// - Anahtarlar sabit ve anlamlı: `alan.konu.öğe` ("request.send").
/// - Yer tutucular konumlu: `%1$@`, `%2$@`… Hepsi metin; sayılar `number(_:)`
///   ile, tarihler `date(_:)` ile biçimlenip verilir (dile göre ayraç).
/// - Çoğul: `key.one` / `key.other`; `plural(_:count:)` seçer.
/// - Eksik çeviri İngilizceye düşer; anahtar ASLA ekrana çıkmaz (test).
/// - Teknik terimler (request, response, header, body, environment, token,
///   API, URL, JSON…) iki dilde de İngilizce kalır; kullanıcı verisi
///   (isimler, header anahtarları, sunucu mesajları) hiç çevrilmez.
public enum L10n {
    public static var language: AppLanguage { Localizer.shared.language }

    /// Çeviri. `args` konumlu `%n$@` yer tutucularına girer.
    public static func t(_ key: String, _ args: String...) -> String {
        format(lookup(key, in: language), args)
    }

    /// Belirli bir dilde (testler ve dil seçici önizlemesi için).
    public static func t(_ key: String, language: AppLanguage, _ args: String...) -> String {
        format(lookup(key, in: language), args)
    }

    /// Sayıya göre `key.one` / `key.other`. İlk yer tutucu (`%1$@`) biçimli
    /// sayıdır; `args` ondan sonra gelir (`%2$@`…).
    public static func plural(_ key: String, count: Int, _ args: String...) -> String {
        let form = count == 1 ? "\(key).one" : "\(key).other"
        let resolved = L10nTable.all[form] != nil ? form : "\(key).other"
        return format(lookup(resolved, in: language), [number(count)] + args)
    }

    /// Dile göre gruplanmış sayı (1.234 / 1,234).
    public static func number(_ value: Int) -> String {
        value.formatted(.number.locale(language.locale))
    }

    public static func number(_ value: Double, fractionDigits: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)).locale(language.locale))
    }

    /// Dile göre kısa tarih + saat.
    public static func date(_ value: Date, time: Bool = true) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: time ? .shortened : .omitted).locale(language.locale))
    }

    /// Dile göre kısa saat.
    public static func time(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(language.locale))
    }

    // MARK: - İç

    static func lookup(_ key: String, in language: AppLanguage) -> String {
        guard let entry = L10nTable.all[key] else {
            // Kodda kullanılıp tabloda olmayan anahtar test tarafından yakalanır;
            // çalışırken ham anahtar göstermek yerine boş değil, okunur bir şey.
            assertionFailure("L10n: eksik anahtar \(key)")
            return ""
        }
        switch language {
        case .turkish: return entry.tr.isEmpty ? entry.en : entry.tr
        case .english: return entry.en.isEmpty ? entry.tr : entry.en
        }
    }

    static func format(_ template: String, _ args: [String]) -> String {
        guard !args.isEmpty else { return template }
        var result = template
        // Konumlu yer tutucular: %1$@ … Sırası dile göre değişebilir.
        for (index, value) in args.enumerated().reversed() {
            result = result.replacingOccurrences(of: "%\(index + 1)$@", with: value)
        }
        return result
    }
}

/// Bir anahtarın iki dildeki metni.
public struct L10nEntry: Sendable {
    public let tr: String
    public let en: String

    public init(_ tr: String, _ en: String) {
        self.tr = tr
        self.en = en
    }
}

/// Tüm metinler. Alanlara göre ayrı dosyalarda (`L10n+*.swift`), burada
/// birleşir. Aynı anahtar iki dosyada tanımlanırsa test yakalar.
public enum L10nTable {
    static let sections: [[String: L10nEntry]] = [
        common, menus, apiClient, response, sidebar, environments, tls, imports, history, secrets,
        tokenFactory, workbench, workbenchTools, diff, messages, core,
    ]

    public static let all: [String: L10nEntry] = sections.reduce(into: [:]) { result, section in
        result.merge(section) { first, _ in first }
    }
}
