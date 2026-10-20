import Foundation
import SwiftUI
import Dev2KitCore

// İsteklerin bulunması, düzenlenmesi ve yaşam döngüsü: ekle, çoğalt, taşı,
// sil; "son gönderilenden farklı" takibi. Kurallar Core'da: `DirtyRequests`,
// `CollectionPorting.uniqueName`, `RequestModel.revertingFunctionalFields`.

extension AppState {
    func request(withID id: UUID) -> RequestModel? {
        locateRequest(id).map { workspace.collections[$0.collection].requests[$0.request] }
    }

    /// İsteğin güncel konumu. Index'ler binding içinde SAKLANMAZ: koleksiyon
    /// sürüklenince veya silinince eski index yanlış isteğe yazar ya da
    /// dizi sınırını aşıp çökertir. Her erişimde ID'den yeniden bulunur.
    func locateRequest(_ id: UUID) -> (collection: Int, request: Int)? {
        for (ci, collection) in workspace.collections.enumerated() {
            if let ri = collection.requests.firstIndex(id: id) {
                return (ci, ri)
            }
        }
        return nil
    }

    /// İsteği yerinde değiştirir. "Bul → kopyala → yaz" dansı on bir yerde
    /// tekrarlanıyordu; index'i yalnızca burası biliyor.
    ///
    /// DİKKAT: `body` içinde `workspace`'e DOKUNMA. Bu çağrı `workspace` üzerinde
    /// yazma erişimi tutar; içeride ayrıca okumak "simultaneous access" hatası
    /// verip uygulamayı çökertir. İhtiyacın olan veriyi önce dışarıda oku.
    /// Salt okuma sorguları için `request(withID:)` kullan.
    ///
    /// - Returns: istek bulunduysa `body`'nin sonucu, yoksa `nil`.
    @discardableResult
    func withRequest<T>(_ id: UUID, _ body: (inout RequestModel) -> T) -> T? {
        guard let location = locateRequest(id) else { return nil }
        return body(&workspace.collections[location.collection].requests[location.request])
    }

    /// İsteğin bulunduğu koleksiyon.
    func collection(containing id: UUID) -> CollectionModel? {
        locateRequest(id).map { workspace.collections[$0.collection] }
    }

    var selectedRequest: Binding<RequestModel>? {
        guard let id = selectedRequestID, let location = locateRequest(id) else { return nil }
        let fallback = workspace.collections[location.collection].requests[location.request]
        return Binding(
            get: {
                guard let current = self.locateRequest(id) else { return fallback }
                return self.workspace.collections[current.collection].requests[current.request]
            },
            set: { newValue in
                guard let current = self.locateRequest(id) else { return }
                self.workspace.collections[current.collection].requests[current.request] = newValue
                // Düzenlenen istek artık "bakılan" değil "kullanılan" istektir.
                if self.previewTabID == id { self.pinTab(id) }
                // Metin düzenlemesi: her tuşta diske yazma, geciktir.
                self.persistSoon()
            }
        )
    }

    // MARK: - "Son gönderilenden farklı" takibi

    /// Son gönderildiği halden farklı isteklerin kimlikleri — TEK geçişte.
    ///
    /// Neden küme: `isDirty(_:)` satır başına çağrıldığında her satırda tüm
    /// koleksiyonları tarayıp (locateRequest) gövde metinlerini karşılaştırıyordu;
    /// 100+ istekte render başına O(n²) iş demekti ve listede takılma yaratıyordu.
    /// View bu kümeyi gövdesinde BİR kez okur, satırlar `contains` ile bakar.
    var dirtyRequestIDs: Set<UUID> {
        DirtyRequests.ids(in: workspace.collections, baselines: workspace.sentBaselines)
    }

    /// İstek en son gönderildiği halden farklı mı.
    /// Hiç gönderilmemiş isteklerde işaret çıkmaz: karşılaştırılacak bir
    /// "test edilmiş hal" yoktur.
    ///
    /// Tek istek için kullanılır (ör. açık isteğin başlığı). Liste/satır
    /// döngüsünde ÇAĞIRMA: orada `dirtyRequestIDs` kullanılır.
    func isDirty(_ id: UUID) -> Bool {
        // `withRequest` DEĞİL: o `workspace`'e yazma erişimi alır, içeride
        // `workspace.sentBaselines` okumak aynı anda erişim demek ve Swift
        // exclusivity kontrolü uygulamayı çökertir (canlı yakalandı).
        // Okuma sorgularında read-only erişimci kullanılır.
        guard let request = request(withID: id) else { return false }
        return DirtyRequests.isDirty(request, baselines: workspace.sentBaselines)
    }

    var lastSentBaseline: RequestModel? {
        guard let id = selectedRequestID else { return nil }
        return workspace.sentBaselines[id.uuidString]
    }

    /// İsteği en son gönderildiği hale döndürür. Ad ve kimlik korunur.
    /// Kaydedilmemiş düzenlemeleri geri alınamaz biçimde siler; çağıran
    /// taraf onay almalı.
    func revertToLastSent(_ id: UUID) {
        guard let baseline = workspace.sentBaselines[id.uuidString] else { return }
        let reverted = withRequest(id) { request in
            request = request.revertingFunctionalFields(to: baseline)
            return true
        }
        guard reverted == true else { return }
        pinTab(id)
        persist()
    }

    func recordBaseline(_ request: RequestModel) {
        workspace.sentBaselines[request.id.uuidString] = request
        workspace.pruneBaselines()
        persist()
    }

    func addRequest(to collectionID: UUID) {
        guard let index = workspace.collections.firstIndex(id: collectionID) else { return }
        let request = RequestModel()
        workspace.collections[index].requests.append(request)
        // Kapalı koleksiyona eklenen istek seçili ama görünmez kalırdı.
        collapsedCollectionIDs.remove(collectionID)
        showRequest(request.id)
        persist()
    }

    /// İsteği verilen yere ekler ve düzenlemek için açar: kapalı koleksiyon
    /// açılır, kenar çubuğu isteğe kayar. Hedef çözülemezse (ör. boş yeni
    /// koleksiyon adı) hiçbir şey yazılmaz. Diğer istekler ve sekmeler
    /// olduğu gibi kalır.
    @discardableResult
    func createRequest(name: String, method: HTTPMethod, destination: CollectionDestination) -> UUID? {
        guard let collectionID = resolve(destination),
              let index = workspace.collections.firstIndex(id: collectionID) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let request = RequestModel(name: trimmed.isEmpty ? RequestModel().name : trimmed, method: method)
        workspace.collections[index].requests.append(request)
        // Filtre ya da kapalı koleksiyon yeni isteği gizlemesin.
        clearSearch()
        collapsedCollectionIDs.remove(collectionID)
        showRequest(request.id)
        sidebarRevealID = request.id
        persist()
        return request.id
    }

    /// Boş durumdaki "yeni bir istek oluştur": varsayılan istek
    /// Koleksiyonsuz'a, adres alanı odakta.
    @discardableResult
    func createUngroupedRequest() -> UUID? {
        let id = createRequest(name: "", method: .get, destination: .ungrouped)
        if id != nil { addressFocusPending = true }
        return id
    }

    /// Adres alanı açılınca odak alacak mı; bir kez okunur.
    func takeAddressFocus() -> Bool {
        defer { addressFocusPending = false }
        return addressFocusPending
    }

    /// ⌘N: yeni isteği en makul koleksiyona ekler — seçili isteğin koleksiyonu,
    /// yoksa ilk koleksiyon. Hiç koleksiyon yoksa bir tane açar; kısayol hiçbir
    /// durumda sessizce hiçbir şey yapmamalı.
    ///
    /// Açık arama temizlenir: yeni isteğin adı filtreye uymayacağı için aksi
    /// halde seçili ama listede görünmeyen bir istek oluşurdu.
    func addRequestToCurrentCollection() {
        clearSearch()
        if let id = selectedRequestID, let current = collection(containing: id) {
            if current.isTokenFactory {
                addTokenFactoryRequest()
                return
            }
            addRequest(to: current.id)
            return
        }
        if let first = workspace.regularCollections.first {
            addRequest(to: first.id)
            return
        }
        let collection = CollectionModel()
        workspace.collections.append(collection)
        addRequest(to: collection.id)
    }

    /// İsteği aynı koleksiyonda hemen altına kopyalar ve seçer.
    /// Ad çakışmasında koleksiyon import'uyla aynı kural: "isim kopya", "isim kopya 2"…
    func duplicateRequest(_ id: UUID) {
        guard let location = locateRequest(id) else { return }
        var copy = workspace.collections[location.collection].requests[location.request]
        copy.id = UUID()
        copy.name = CollectionPorting.uniqueName(
            copy.name,
            suffix: "kopya",
            existingNames: workspace.collections[location.collection].requests.map(\.name)
        )
        // Token Factory'de kopya aynı değişkeni yazmaya kalkmasın: çakışma
        // uyarısıyla başlamak yerine boş bir ad alır.
        if workspace.collections[location.collection].isTokenFactory {
            var output = copy.tokenOutput ?? TokenOutput()
            output.variableName = uniqueTokenVariableName(base: output.trimmedVariableName)
            copy.tokenOutput = output
        }
        workspace.collections[location.collection].requests.insert(copy, at: location.request + 1)
        showRequest(copy.id)
        persist()
    }

    /// İsteği başka bir koleksiyona taşır (hedefin sonuna eklenir).
    func moveRequest(_ id: UUID, toCollection targetID: UUID) {
        moveRequests([id], toCollection: targetID)
    }

    /// Seçili istekleri başka bir koleksiyona taşır; kaynak sıraları korunur.
    /// Ad çakışması tek istekteki kuralla aynı: "isim taşınan", "isim taşınan 2"…
    func moveRequests(_ ids: Set<UUID>, toCollection targetID: UUID) {
        guard !ids.isEmpty,
              let target = workspace.collections.firstIndex(id: targetID),
              // Token Factory'ye taşınarak girilmez, taşınarak çıkılmaz: oradaki
              // istek tüm isteklere token yazar; bunun bir taşıma yan etkisi
              // olarak başlaması ya da bitmesi beklenmez.
              !workspace.collections[target].isTokenFactory else { return }
        var moved: [RequestModel] = []
        for index in workspace.collections.indices
        where index != target && !workspace.collections[index].isTokenFactory {
            let picked = workspace.collections[index].requests.filter { ids.contains($0.id) }
            guard !picked.isEmpty else { continue }
            workspace.collections[index].requests.removeAll { ids.contains($0.id) }
            moved.append(contentsOf: picked)
        }
        guard !moved.isEmpty else { return }
        for var request in moved {
            let existing = workspace.collections[target].requests.map(\.name)
            request.name = CollectionPorting.uniqueName(request.name, suffix: "taşınan", existingNames: existing)
            workspace.collections[target].requests.append(request)
        }
        // Taşınanlar seçili kalsın: kullanıcı nereye gittiklerini görsün.
        selectedRequestIDs = Set(moved.map(\.id))
        selectedRequestID = moved.last?.id
        persist()
    }

    /// İsteği koleksiyonsuz bölüme taşır.
    func removeFromCollection(_ id: UUID) {
        removeFromCollection([id])
    }

    func removeFromCollection(_ ids: Set<UUID>) {
        moveRequests(ids, toCollection: workspace.ensureUngroupedCollection())
    }

    /// İçe aktarılan isteğin gideceği yer.
    enum CollectionDestination: Hashable {
        case ungrouped
        case existing(UUID)
        /// Aynı adda bir koleksiyon zaten varsa ona eklenir; kopyası açılmaz.
        case new(name: String)
    }

    /// Hedefi koleksiyon kimliğine çevirir; gerekiyorsa kabı ya da koleksiyonu oluşturur.
    func resolve(_ destination: CollectionDestination) -> UUID? {
        switch destination {
        case .ungrouped:
            return workspace.ensureUngroupedCollection()
        case .existing(let id):
            return workspace.collections.contains { $0.id == id } ? id : nil
        case .new(let rawName):
            let name = rawName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            if let existing = existingCollection(named: name) { return existing.id }
            let collection = CollectionModel(name: name)
            workspace.collections.append(collection)
            return collection.id
        }
    }

    func deleteRequest(_ id: UUID) {
        deleteRequests([id])
    }

    /// Seçili isteklerin tamamını siler. Tek yazım, tek geri bildirim.
    func deleteRequests(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for index in workspace.collections.indices {
            workspace.collections[index].requests.removeAll { ids.contains($0.id) }
        }
        ids.forEach { closeTab($0) }
        selectedRequestIDs.subtract(ids)
        if let id = selectedRequestID, ids.contains(id) { selectedRequestID = nil }
        persist()
    }

    func moveRequests(in collectionID: UUID, from source: IndexSet, to destination: Int) {
        guard let index = workspace.collections.firstIndex(id: collectionID) else { return }
        workspace.collections[index].requests.move(fromOffsets: source, toOffset: destination)
        persist()
    }
}
