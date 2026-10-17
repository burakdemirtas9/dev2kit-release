import Foundation
import Dev2KitCore

// Açık istek sekmeleri. Kurallar `RequestTabs`'ta (Core, testli); burası
// seçimle bağlar ve kalıcı sekmeleri UserDefaults'a yazar.
//
// `openTab`, `saveTabs`, `pruneTabs` `private` DEĞİL: ana dosyadaki
// `selectedRequestID.didSet` ve `persist()` çağırıyor; uzantılar aynı modülde.

extension AppState {
    static let openTabsKey = "openTabs"
    static let selectedTabKey = "selectedTab"

    func openTab(_ id: UUID) {
        tabs.open(id)
    }

    /// Sekmeyi kalıcı yapar (açık değilse açar).
    func pinTab(_ id: UUID) {
        tabs.pin(id)
        saveTabs()
    }

    /// Sekmeyi kapatır; seçiliyse sağındaki, yoksa solundaki seçilir.
    func closeTab(_ id: UUID) {
        selectedRequestID = tabs.close(id, selected: selectedRequestID)
        saveTabs()
    }

    func closeOtherTabs(_ id: UUID) {
        selectedRequestID = tabs.closeOthers(keeping: id)
        saveTabs()
    }

    func closeTabsToRight(of id: UUID) {
        selectedRequestID = tabs.closeToRight(of: id, selected: selectedRequestID)
        saveTabs()
    }

    /// Sürükle-bırak: sekmeyi hedefin konumuna taşır.
    func moveTab(_ id: UUID, before targetID: UUID) {
        tabs.move(id, before: targetID)
        saveTabs()
    }

    /// ⌥⌘→ / ⌥⌘←: sonraki / önceki sekme, uçlarda başa sarar.
    func selectAdjacentTab(_ offset: Int) {
        if let next = tabs.adjacent(to: selectedRequestID, offset: offset) { selectedRequestID = next }
    }

    /// İsteği seçer ve sekmesini kalıcı yapar: yeni eklenen, çoğaltılan,
    /// geçmişten geri yüklenen ya da öneriden açılan istek "bakılan" değil
    /// "kullanılan" istektir.
    func showRequest(_ id: UUID) {
        selectedRequestID = id
        pinTab(id)
    }

    /// Kalıcı sekmeler ve seçili sekme bir sonraki açılışa taşınır; önizleme
    /// sekmesi geçici olduğu için taşınmaz.
    func saveTabs() {
        let permanent = tabs.permanent.map(\.uuidString)
        UserDefaults.standard.set(permanent, forKey: Self.openTabsKey)
        let selected = selectedRequestID.flatMap { permanent.contains($0.uuidString) ? $0.uuidString : nil }
        UserDefaults.standard.set(selected, forKey: Self.selectedTabKey)
    }

    /// Silinmiş isteklerin sekmeleri atılır.
    func pruneTabs() {
        let live = Set(workspace.collections.flatMap { $0.requests.map(\.id) })
        guard openTabs.contains(where: { !live.contains($0) }) else { return }
        selectedRequestID = tabs.prune(keeping: live, selected: selectedRequestID)
        saveTabs()
    }

    /// Açılışta önceki oturumun kalıcı sekmeleri ve seçimi geri yüklenir;
    /// silinmiş isteklerin sekmeleri atlanır.
    func restoreTabs() {
        let live = Set(workspace.collections.flatMap { $0.requests.map(\.id) })
        tabs = RequestTabs(tabs: (UserDefaults.standard.stringArray(forKey: Self.openTabsKey) ?? [])
            .compactMap(UUID.init(uuidString:))
            .filter(live.contains))
        let savedSelection = UserDefaults.standard.string(forKey: Self.selectedTabKey).flatMap(UUID.init(uuidString:))
        selectedRequestID = savedSelection.flatMap { openTabs.contains($0) ? $0 : nil } ?? openTabs.first
    }
}
