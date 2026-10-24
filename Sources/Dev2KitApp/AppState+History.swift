import AppKit
import Foundation
import SwiftUI
import Dev2KitCore

/// Geçmiş: kayıt tutma, temizleme ve geçmişten geri yükleme.
/// `AppState`'ten ayrıldı — dosya 1.500 satırı geçince hangi işin nerede
/// olduğunu bulmak zorlaşıyordu. Davranış aynı, yalnızca yeri değişti.

extension AppState {
    func reloadHistory() {
        history = historyStore.entries()
    }

    func clearHistory() {
        historyStore.deleteAll()
        reloadHistory()
    }

    /// Kaydın tamamı (içerik dosyası arka planda okunur).
    func loadHistoryEntry(_ id: UUID) async -> HistoryEntry? {
        let store = historyStore
        return await Task.detached(priority: .userInitiated) { store.fullEntry(id: id) }.value
    }

    func deleteHistoryEntry(_ id: UUID) {
        historyStore.delete(id: id)
        reloadHistory()
    }

    /// Geçmişteki hali mevcut isteğe geri yazar.
    /// Maskelenmiş alanlar geri yüklenmez: "••••••" değerini isteğe yazmak
    /// çalışan bir kimlik bilgisini sessizce bozardı.
    func restore(_ entry: HistoryEntry) -> Bool {
        guard let requestID = entry.requestID else { return false }
        // Listedeki kayıt içeriksiz; gövde içerik dosyasından.
        let full = historyStore.fullEntry(id: entry.id) ?? entry
        let restored = withRequest(requestID) { request in
            request = HistoryRestore.apply(full.snapshot, to: request)
            return request.id
        }
        guard let id = restored else { return false }
        showRequest(id)
        persist()
        return true
    }

    /// Geçmişteki isteği yeni bir istek olarak ekler (silinmiş isteği kurtarmak için).
    func restoreAsNewRequest(_ entry: HistoryEntry, to collectionID: UUID) {
        var snapshot = (historyStore.fullEntry(id: entry.id) ?? entry).snapshot
        snapshot.name = entry.requestName
        addImportedRequest(snapshot, to: collectionID)
    }

    /// Gönderim sonucunu geçmişe yazar. Anlık görüntü ŞABLON halidir ve
    /// ham kimlik bilgileri maskelenir.
    /// `private` değil: gönderim akışı (AppState) buradan çağırıyor.
    func recordHistory(_ request: RequestModel, outcome: HistoryEntry.Outcome, responseText: String?) {
        guard historySettings.isEnabled else { return }
        let collectionName = workspace.collections.first { collection in
            collection.requests.contains { $0.id == request.id }
        }?.name
        let preview = historySettings.storeResponseBodies
            ? responseText.map { HistoryRedactor.redactResponse($0, limit: historySettings.responsePreviewLimit) }
            : nil
        let entry = HistoryEntry(
            requestID: request.id,
            requestName: request.name,
            collectionName: collectionName,
            environmentName: activeEnvironment?.name,
            method: request.method,
            url: HistoryRedactor.maskURL(request.url),
            outcome: outcome,
            snapshot: HistoryTrimmer.trim(
                // Geçmiş isteği anlatır; kayıtlı örnek yanıtlar oraya girmez.
                HistoryRedactor.redact(request.withoutExamples),
                maxBodyBytes: historySettings.maxSnapshotBodyBytes
            ),
            responsePreview: preview
        )
        history = historyStore.append(entry, settings: historySettings)
    }
}

// MARK: - Geçmiş dosyası

extension AppState {
    /// Geçmiş dosyasının diskteki boyutu.
    var historyFileSize: Int { historyStore.fileSizeBytes() }

    func clearHistory(environmentName: String?) {
        historyStore.deleteEntries(environmentName: environmentName)
        reloadHistory()
    }
}
