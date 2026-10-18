import AppKit
import Foundation
import SwiftUI
import Dev2KitCore

/// İçe/dışa aktarma: dosya ve Postman hesabı, cURL, Kibana, OpenAPI ve kaynak
/// kodu taraması. Hepsi aynı iskeleti paylaşır: kaynaktan koleksiyon üret →
/// `ImportReviewer`'dan geçir → kullanıcı onaylarsa workspace'e yaz.

extension AppState {
    /// Adresten OpenAPI dokümanını bulur. İndirme, istek motoru üzerinden
    /// yapılır: yönetici politikası, http/https dışı adres engeli, yönlendirme
    /// koruması ve kurum CA'sı burada da geçerlidir. Kimlik bilgisi gönderilmez.
    func discoverOpenAPI(_ address: String) async throws -> OpenAPIDiscovery.Outcome {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else {
            throw OpenAPIFetchError(message: "Geçerli bir http ya da https adresi gir, ör. http://localhost:8080/v3/api-docs")
        }
        let engine = self.engine
        let policy = hostPolicy
        let approved = approvalStore.load()
        return try await OpenAPIDiscovery.discover(from: url) { candidate in
            let request = RequestModel(
                name: "OpenAPI",
                method: .get,
                url: candidate.absoluteString,
                headers: [KeyValueEntry(key: "Accept", value: "application/json")]
            )
            // Güvenlik engeli, bağlantı ve TLS hataları olduğu gibi yukarı çıkar:
            // keşif durur ve kullanıcı asıl sebebi görür.
            let response = try await engine.send(
                request,
                environment: nil,
                secretStore: InMemorySecretStore(),
                hostPolicy: policy,
                approvedWarnings: approved
            )
            guard (200..<300).contains(response.statusCode) else {
                throw OpenAPIDiscovery.HTTPStatusError(url: candidate, statusCode: response.statusCode)
            }
            guard response.body.count <= ImportReviewer.maxImportBytes else {
                throw OpenAPIFetchError(message: "Doküman çok büyük; en fazla \(ImportReviewer.maxImportBytes / 1_048_576) MB.")
            }
            return response.body
        }
    }

    /// Dokümandan koleksiyon kurar ve içe aktarma incelemesinden geçirir.
    func prepareOpenAPIImport(_ document: OpenAPIImporter.Document, variableName: String) -> Result<PreparedImport, ImportFailure> {
        do {
            let outcome = try OpenAPIImporter.makeCollection(
                from: document,
                variableName: variableName,
                existingNames: workspace.collections.map(\.name)
            )
            let review = ImportReviewer.review(collection: outcome.collection, notes: outcome.warnings, context: importContext)
            return .success(PreparedImport(review: review, wasRenamed: outcome.wasRenamed))
        } catch {
            return .failure(ImportFailure(message: "Koleksiyon oluşturulamadı: \(error.localizedDescription)"))
        }
    }

    /// Proje klasörünü arka planda okur. Yalnızca okuma: derleme, çalıştırma
    /// ya da ağ erişimi yoktur.
    nonisolated func scanOutbound(_ directory: URL) async throws -> OutboundScanResult {
        try await Task.detached(priority: .userInitiated) {
            let accessing = directory.startAccessingSecurityScopedResource()
            defer { if accessing { directory.stopAccessingSecurityScopedResource() } }
            return try OutboundScanner.scan(directory: directory)
        }.value
    }

    func prepareOutboundImport(
        _ result: OutboundScanResult,
        variables: [OutboundCollectionBuilder.Variable]
    ) -> Result<PreparedImport, ImportFailure> {
        do {
            let outcome = try OutboundCollectionBuilder.makeCollection(
                from: result,
                variables: variables,
                existingNames: workspace.collections.map(\.name)
            )
            let review = ImportReviewer.review(collection: outcome.collection, notes: outcome.warnings, context: importContext)
            return .success(PreparedImport(review: review, wasRenamed: outcome.wasRenamed))
        } catch {
            return .failure(ImportFailure(message: "Koleksiyon oluşturulamadı: \(error.localizedDescription)"))
        }
    }

    /// Kibana logundan üretilen isteği ekler ya da seçili isteğin üzerine yazar.
    /// Sıra bilinçli: önce token'lar vault'a yazılır; bu başarısız olursa istek
    /// oluşturulmaz, yani vault'ta karşılığı olmayan bir `{{secret:…}}`
    /// referansı kalmaz. Adres değişkeni yalnızca aktif environment'ta yoksa eklenir.
    func importFromKibana(
        _ output: KibanaImporter.Output,
        target: KibanaImportTarget,
        variable: (name: String, value: String)?
    ) throws {
        for secret in output.secrets {
            try secretStore.setSecret(secret.value, forName: secret.name)
        }
        if !output.secrets.isEmpty { invalidateSecretNames() }

        if let variable { addVariableToActiveEnvironmentIfMissing(variable.name, value: variable.value) }

        switch target {
        case .newRequest(let destination):
            // Koleksiyon, token'lar vault'a yazıldıktan SONRA oluşturulur:
            // yazma başarısızsa boş bir koleksiyon açılmış olmasın.
            guard let collectionID = resolve(destination) else { return }
            addImportedRequest(output.request, to: collectionID)
        case .selectedRequest:
            selectedRequest?.wrappedValue = output.request
        }
    }

    func importCollection(from url: URL, source: ImportSource) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= ImportReviewer.maxImportBytes else {
            portingMessage = "Dosya çok büyük (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))); en fazla \(ImportReviewer.maxImportBytes / 1_048_576) MB içe aktarılır."
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            portingMessage = "Dosya okunamadı: \(error.localizedDescription)"
            return
        }
        switch prepareImport(data, source: source) {
        case .success(let prepared): importPrepared(prepared)
        case .failure(let failure): portingMessage = failure.message
        }
    }

    /// Hazırlanmış koleksiyonları ekler ya da birlikte incelemeye gönderir.
    func importPrepared(_ prepared: PreparedImport) {
        importPrepared([prepared])
    }

    func importPrepared(_ items: [PreparedImport]) {
        guard !items.isEmpty else { return }
        if items.allSatisfy(\.review.isClean) {
            // Bulgu yoksa ek bir onay adımı gereksiz sürtünme olurdu.
            portingMessage = commitImport(items)
        } else {
            pendingImport = PendingImport(items: items)
        }
    }

    /// Otomatik içe aktarmada bulunan cURL istekleri: tek koleksiyon olarak,
    /// koleksiyon içe aktarmasıyla AYNI güvenlik incelemesinden geçer
    /// (token/parola içeren başlıklar, bilinmeyen sunucular).
    func prepareCollectionImport(name: String, requests: [RequestModel], notes: [String]) -> PreparedImport {
        let existing = workspace.collections.map(\.name)
        let unique = CollectionPorting.uniqueName(name, suffix: "2", existingNames: existing)
        let collection = CollectionModel(name: unique, requests: requests)
        let review = ImportReviewer.review(collection: collection, notes: notes, context: importContext)
        return PreparedImport(review: review, wasRenamed: unique != name)
    }

    /// Veriyi çözümler ve inceler; çalışma alanına HENÜZ eklemez.
    /// - Parameter reservedNames: Aynı turda hazırlanan diğer koleksiyonların
    ///   adları; birlikte onaylandıklarında ad çakışmasın.
    func prepareImport(_ data: Data, source: ImportSource, reservedNames: [String] = []) -> Result<PreparedImport, ImportFailure> {
        guard data.count <= ImportReviewer.maxImportBytes else {
            return .failure(ImportFailure(message: "Koleksiyon çok büyük; en fazla \(ImportReviewer.maxImportBytes / 1_048_576) MB içe aktarılır."))
        }
        do {
            let existingNames = workspace.collections.map(\.name) + reservedNames
            let outcome: CollectionPorting.ImportOutcome
            switch source {
            case .dev2kit:
                outcome = try CollectionPorting.importDev2Kit(data, existingNames: existingNames)
            case .postman:
                outcome = try CollectionPorting.importPostman(data, existingNames: existingNames)
            }
            let review = ImportReviewer.review(collection: outcome.collection, notes: outcome.warnings, context: importContext)
            return .success(PreparedImport(review: review, wasRenamed: outcome.wasRenamed))
        } catch {
            return .failure(ImportFailure(message: "İçe aktarma başarısız: \(error.localizedDescription)"))
        }
    }

    /// Onaylanan koleksiyonları ekler; kesin engelli istekler dışarıda kalır.
    /// Kullanıcıya gösterilecek özet metnini döner.
    @discardableResult
    func commitImport(_ items: [PreparedImport]) -> String {
        var lines: [String] = []
        for item in items {
            let collection = item.review.importableCollection
            let skipped = item.review.blockedCount
            if collection.requests.isEmpty, skipped > 0 {
                lines.append("\"\(collection.name)\" aktarılmadı: tüm istekler güvenlik nedeniyle engellendi.")
                continue
            }
            workspace.collections.append(collection)
            lines.append("\"\(collection.name)\" içe aktarıldı (\(collection.requests.count) istek).")
            if skipped > 0 {
                lines.append("\(skipped) istek güvenlik nedeniyle aktarılmadı.")
            }
            if item.wasRenamed {
                lines.append("İsim çakıştığı için \"\(collection.name)\" olarak eklendi.")
            }
            lines.append(contentsOf: item.review.notes.map { "⚠︎ \($0)" })
        }
        persist()
        return lines.joined(separator: "\n")
    }

    func exportCollection(_ id: UUID) {
        guard let collection = workspace.collections.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(collection.name).dev2kit.json"
        panel.title = "Koleksiyonu Dışa Aktar"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CollectionPorting.exportData(collection).write(to: url)
            portingMessage = "\"\(collection.name)\" dışa aktarıldı.\nSecret değerleri dosyada YOK; yalnızca {{secret:isim}} referansları var."
        } catch {
            portingMessage = "Dışa aktarma başarısız: \(error.localizedDescription)"
        }
    }

    func existingCollection(named name: String) -> CollectionModel? {
        let target = name.trimmingCharacters(in: .whitespaces)
        return workspace.regularCollections.first { $0.name.caseInsensitiveCompare(target) == .orderedSame }
    }

    /// Dışarıdan gelen (curl vb.) isteği koleksiyona ekler ve seçer.
    /// Ad çakışması koleksiyon import'uyla aynı kurala göre çözülür.
    func addImportedRequest(_ request: RequestModel, to collectionID: UUID) {
        guard let index = workspace.collections.firstIndex(id: collectionID) else { return }
        // Seçilen istek görünür olmalı: arama filtresine uymayabilir ya da
        // hedef koleksiyon kapalı olabilir.
        clearSearch()
        collapsedCollectionIDs.remove(collectionID)
        var copy = request
        copy.id = UUID()
        let existing = workspace.collections[index].requests.map(\.name)
        copy.name = CollectionPorting.uniqueName(copy.name, suffix: "2", existingNames: existing)
        workspace.collections[index].requests.append(copy)
        showRequest(copy.id)
        persist()
    }

    func curlCommand(for request: RequestModel, includeSecrets: Bool) -> String {
        // Token Factory: bellekte geçerli token varsa o, yoksa değişken adı yazılır.
        let (environment, store) = cachedTokenBindings(for: activeEnvironment)
        do {
            return try CurlExporter.export(
                request,
                environment: environment,
                secretStore: store,
                includeSecrets: includeSecrets
            )
        } catch {
            return "# cURL üretilemedi: \(error.localizedDescription)"
        }
    }
}

// MARK: - İçe aktarma tipleri

extension AppState {
    struct OpenAPIFetchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum KibanaImportTarget {
        case newRequest(CollectionDestination)
        case selectedRequest
    }

    enum ImportSource {
        case dev2kit
        case postman
    }

    /// İncelemeden geçmiş, onay bekleyen içe aktarma.
    struct PreparedImport: Identifiable {
        let review: CollectionReview
        let wasRenamed: Bool
        var id: UUID { review.id }
    }

    /// Kullanıcının kararını bekleyen dosya içe aktarması; kenar çubuğu
    /// inceleme ekranını bunun için açar.
    struct PendingImport: Identifiable {
        let id = UUID()
        let items: [PreparedImport]
    }

    struct ImportFailure: Error {
        let message: String
    }

    var importContext: ImportReviewer.Context {
        ImportReviewer.Context(policy: hostPolicy, vaultSecretNames: Set(secretNames))
    }
}
