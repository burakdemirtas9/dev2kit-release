import Foundation
import XCTest
@testable import Dev2KitApp
@testable import Dev2KitCore

/// `AppState` testleri için izole ortam.
///
/// İki şeyi garanti eder:
/// 1. Test, kullanıcının gerçek verisine DOKUNMAZ. `DEV2KIT_DATA_DIR` geçici bir
///    dizine çevrilir; workspace, geçmiş, secret ve onay dosyaları oraya gider.
/// 2. Her test temiz başlar: dizin ve ilgili UserDefaults anahtarları silinir.
@MainActor
final class AppStateHarness {
    let directory: URL
    let store: WorkspaceStore
    let state: AppState

    /// Testler arasında sızmaması gereken arayüz tercihleri.
    private static let defaultsKeys = [
        "openTabs", "selectedTab", "collapsedCollections", "appearanceMode",
        "historySettings", "sidebarWidth",
    ]

    init() {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dev2kit-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv(AppPaths.directoryEnvironmentKey, directory.path, 1)
        Self.defaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }

        store = WorkspaceStore(directory: directory)
        state = AppState(store: store, secretStore: FileSecretStore())
        // Makinedeki gerçek yönetici politikası testleri etkilemesin (bozuk ya
        // da kısıtlı bir dosya, ilgisiz testleri düşürüyordu).
        state.hostPolicyForTesting = .notConfigured
    }

    func tearDown() {
        state.waitForPendingWrites()
        unsetenv(AppPaths.directoryEnvironmentKey)
        Self.defaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Kısayollar

    /// İlk koleksiyon (AppState boş workspace'te bir tane oluşturur).
    var firstCollection: CollectionModel { state.workspace.collections[0] }

    /// Diske yazılmış hali — kaydetmenin gerçekten çalıştığını doğrulamak için.
    func savedWorkspace() throws -> WorkspaceModel {
        state.waitForPendingWrites()
        return try store.load()
    }

    @discardableResult
    func addRequest(named name: String, url: String = "https://api.example.com") -> RequestModel {
        state.addRequest(to: firstCollection.id)
        guard let id = state.selectedRequestID, var request = state.request(withID: id) else {
            fatalError("eklenen istek seçili olmalıydı")
        }
        request.name = name
        request.url = url
        state.selectedRequest?.wrappedValue = request
        return request
    }
}
