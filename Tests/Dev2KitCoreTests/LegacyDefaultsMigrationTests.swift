import XCTest
@testable import Dev2KitCore

/// Bundle kimliği değişiminde eski ayarların bir kez, ezmeden taşınması.
final class LegacyDefaultsMigrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "dev2kit.tests.legacy-defaults.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testCopiesMissingKeys() {
        let copied = LegacyDefaultsMigration.migrate(
            from: ["appLanguage": "en", "sidebarWidth": 260.0, "openTabs": ["a", "b"]],
            into: defaults)
        XCTAssertEqual(copied, 3)
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "en")
        XCTAssertEqual(defaults.double(forKey: "sidebarWidth"), 260)
        XCTAssertEqual(defaults.stringArray(forKey: "openTabs"), ["a", "b"])
    }

    func testDoesNotOverwriteNewValues() {
        defaults.set("tr", forKey: "appLanguage")
        let copied = LegacyDefaultsMigration.migrate(from: ["appLanguage": "en", "appMode": "workbench"], into: defaults)
        XCTAssertEqual(copied, 1)
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "tr")
        XCTAssertEqual(defaults.string(forKey: "appMode"), "workbench")
    }

    func testRunsOnlyOnce() {
        LegacyDefaultsMigration.migrate(from: ["appMode": "workbench"], into: defaults)
        defaults.removeObject(forKey: "appMode")
        // Kullanıcı sonradan sildiyse/sıfırladıysa eski değer geri gelmez.
        XCTAssertEqual(LegacyDefaultsMigration.migrate(from: ["appMode": "workbench"], into: defaults), 0)
        XCTAssertNil(defaults.object(forKey: "appMode"))
    }

    func testMissingLegacyDomainOnlyMarksDone() {
        XCTAssertEqual(LegacyDefaultsMigration.migrate(from: nil, into: defaults), 0)
        XCTAssertTrue(defaults.bool(forKey: LegacyDefaultsMigration.doneKey))
    }

    func testBundleIdentifierChanged() {
        XCTAssertNotEqual(Dev2KitIdentity.bundleIdentifier, LegacyDefaultsMigration.legacyDomain)
    }
}
