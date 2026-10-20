import XCTest
@testable import Dev2KitCore

/// Çeviri tablosunun bütünlüğü: kodda kullanılan her anahtar var, iki dilde
/// yer tutucular aynı, aynı anahtar iki kez tanımlı değil, ham anahtar ekrana
/// çıkmaz.
final class LocalizationTests: XCTestCase {
    private static let sourcesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    /// Kaynaklardaki `L10n.t("…"` ve `L10n.plural("…"` anahtarları.
    private func usedKeys() throws -> [(key: String, file: String)] {
        let pattern = try NSRegularExpression(pattern: #"L10n\.(t|plural)\(\s*"([^"]+)""#)
        var keys: [(String, String)] = []
        let enumerator = FileManager.default.enumerator(at: Self.sourcesRoot, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator where url.pathExtension == "swift" && !url.path.contains("/Localization/") {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = String(text[Range(match.range(at: 2), in: text)!])
                let isPlural = text[Range(match.range(at: 1), in: text)!] == "plural"
                keys.append((isPlural ? "\(key).other" : key, url.lastPathComponent))
            }
        }
        return keys
    }

    func testEveryKeyUsedInCodeExists() throws {
        let used = try usedKeys()
        XCTAssertFalse(used.isEmpty)
        let missing = used.filter { L10nTable.all[$0.key] == nil }
        XCTAssertTrue(missing.isEmpty, "Tabloda olmayan anahtarlar: \(missing.map { "\($0.key) (\($0.file))" })")
    }

    func testNoKeyIsDefinedTwice() {
        var seen: [String: Int] = [:]
        for section in L10nTable.sections { for key in section.keys { seen[key, default: 0] += 1 } }
        XCTAssertEqual(seen.filter { $0.value > 1 }.map(\.key).sorted(), [])
    }

    func testBothLanguagesExistAndPlaceholdersMatch() throws {
        let placeholder = try NSRegularExpression(pattern: #"%(\d+)\$@"#)
        func placeholders(_ text: String) -> Set<String> {
            Set(placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range(at: 1), in: text)!])
            })
        }
        for (key, entry) in L10nTable.all {
            XCTAssertFalse(entry.en.isEmpty, "\(key): İngilizce boş (geri dönüş dili)")
            XCTAssertFalse(entry.tr.isEmpty, "\(key): Türkçe boş")
            XCTAssertEqual(placeholders(entry.tr), placeholders(entry.en), "\(key): yer tutucular farklı")
            XCTAssertFalse(entry.en.contains("%@") || entry.tr.contains("%@"), "\(key): konumsuz %@ kullanılmaz")
        }
    }

    func testPluralKeysHaveBothForms() {
        for key in L10nTable.all.keys where key.hasSuffix(".one") {
            let base = String(key.dropLast(".one".count))
            XCTAssertNotNil(L10nTable.all["\(base).other"], "\(base): .other yok")
        }
    }

    func testFormattingAndFallback() {
        XCTAssertEqual(L10n.format("%2$@ – %1$@", ["a", "b"]), "b – a")
        XCTAssertEqual(L10n.t("common.ok", language: .turkish), "Tamam")
        XCTAssertEqual(L10n.t("common.ok", language: .english), "OK")
    }

    func testFirstLaunchFollowsSystemLanguage() {
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["tr-TR", "en-US"]), .turkish)
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["de-DE", "tr-TR"]), .english)
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: []), .english)
    }

    func testPreferenceIsSavedAndRestored() {
        let defaults = UserDefaults(suiteName: "L10nTest-\(UUID().uuidString)")!
        defaults.set("en", forKey: Localizer.defaultsKey)
        XCTAssertEqual(Localizer(defaults: defaults, environment: [:]).language, .english)
        defaults.set("tr", forKey: Localizer.defaultsKey)
        XCTAssertEqual(Localizer(defaults: defaults, environment: [:]).language, .turkish)
    }

    /// DEV2KIT_LANGUAGE kayıtlı tercihin önüne geçer; geçersiz değer yok sayılır.
    func testEnvironmentOverridesTheSavedPreference() {
        let defaults = UserDefaults(suiteName: "L10nTest-\(UUID().uuidString)")!
        defaults.set("tr", forKey: Localizer.defaultsKey)
        XCTAssertEqual(Localizer(defaults: defaults, environment: ["DEV2KIT_LANGUAGE": "en"]).language, .english)
        XCTAssertEqual(Localizer(defaults: defaults, environment: ["DEV2KIT_LANGUAGE": "xx"]).language, .turkish)
    }
}
