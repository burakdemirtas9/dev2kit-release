import AppKit
import Foundation
import Dev2KitCore

// Kenar çubuğunun durumdan türeyen görünümü: arama sonucu, daraltılmış
// koleksiyonlar, genişlik sınırı. Arama kuralı Core'da (`RequestSearch`).

extension AppState {
    /// Her satır için ayrı ayrı sorulduğundan ucuz tutuldu: `tokens(from:)`
    /// ile aynı sonucu verir (yalnızca boşluktan oluşan sorgu arama sayılmaz)
    /// ama dizi ayırmaz.
    var isSearching: Bool {
        searchQuery.contains { !$0.isWhitespace }
    }

    /// Sidebar'da gösterilecek koleksiyonlar; arama boşsa hepsi.
    /// Token Factory hariç: o, listenin altında kendi bölümünde.
    var visibleCollections: [RequestSearch.Match] {
        RequestSearch.filter(workspace.collections.filter { !$0.isTokenFactory }, query: searchQuery)
    }

    /// Arama sonucundaki ilk istek — arama alanında ⏎ ile seçilir.
    var firstSearchHit: RequestModel? {
        visibleCollections.first(where: { !$0.requests.isEmpty })?.requests.first
    }

    func isCollectionCollapsed(_ id: UUID) -> Bool {
        collapsedCollectionIDs.contains(id)
    }

    func toggleCollectionCollapsed(_ id: UUID) {
        if collapsedCollectionIDs.contains(id) {
            collapsedCollectionIDs.remove(id)
        } else {
            collapsedCollectionIDs.insert(id)
        }
    }

    func areExamplesExpanded(_ requestID: UUID) -> Bool {
        expandedExampleRequestIDs.contains(requestID)
    }

    /// İsteğin örneklerini açar/katlar. Katlanan isteğin örneği açıksa istek
    /// düzenleyicisine dönülür (macOS ağaç görünümündeki gibi seçim üst
    /// öğeye geçer): gizlenen satır seçili kalmasın.
    func toggleExamples(_ requestID: UUID) {
        if expandedExampleRequestIDs.contains(requestID) {
            expandedExampleRequestIDs.remove(requestID)
            if openExample?.requestID == requestID { openExample = nil }
        } else {
            expandedExampleRequestIDs.insert(requestID)
        }
    }

    /// Sidebar'ın genişleyebileceği üst sınır: en uzun koleksiyon/istek adının
    /// gerçek piksel genişliği + nefes payı. Kullanıcı ayracı bundan öteye çekemez.
    ///
    /// Her render'da çağrıldığı için Core Text ölçümü yalnızca en uzun ADAYLARA
    /// uygulanır: önce ucuz karakter sayısıyla eleme yapılır, sonra tek tek ölçüm.
    /// (Tüm isimleri ölçmek yazarken gözle görülür takılmaya yol açıyordu.)
    var sidebarMaxWidth: CGFloat {
        var longestHeader = ""
        var longestRow = ""
        for collection in workspace.collections {
            if collection.name.count > longestHeader.count { longestHeader = collection.name }
            for request in collection.requests where request.name.count > longestRow.count {
                longestRow = request.name
            }
        }
        let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        let rowFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            text.isEmpty ? 0 : (text as NSString).size(withAttributes: [.font: font]).width
        }
        // başlık: chevron + tutamaç + padding ≈ 64px · satır: örnek oku (22) +
        // metot sütunu + boşluk + örnek sayısı ≈ 124px
        let widest = max(width(longestHeader, headerFont) + 64, width(longestRow, rowFont) + 124)
        return max(SidebarSizing.baseMinimum, widest + 36)
    }
}
