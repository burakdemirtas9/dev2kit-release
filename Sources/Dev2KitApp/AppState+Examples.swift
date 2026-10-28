import Foundation
import SwiftUI
import Dev2KitCore

/// Response örnekleri: kaydetme (sınır uyarısıyla), görüntüleme, "Dene" ile
/// isteğe dönüş, yeniden adlandırma ve silme. Kurallar Core'da
/// (`ResponseExamples`); burası durumu yönetir ve kaydeder.
///
/// Değişmez: örnek açıkken (`openExample != nil`) `send` ağa çıkmaz; istek
/// düzenleyicisine döner. Örnek görüntülemek isteği, son canlı yanıtı ve
/// sekmeleri değiştirmez.

extension AppState {
    /// Bir örneğin adresi: hangi isteğin hangi örneği.
    struct ExampleRef: Hashable {
        let requestID: UUID
        let exampleID: UUID
    }

    /// Kaydetme akışı. Anlık görüntü (`snapshot`) akış başında BİR kez alınır;
    /// ad değişse, örnek silinse, bu arada yeni yanıt gelse de aynı kalır.
    struct PendingExampleSave: Identifiable {
        enum Phase: Equatable {
            /// Görüntü arka planda hazırlanıyor (maskeleme).
            case preparing
            /// Sınır dolu: uyarı kutusu.
            case limitWarning
            /// Ad girişi ve (sınır doluysa) mevcut örneklerin yönetimi.
            case naming
        }

        let id = UUID()
        let requestID: UUID
        var snapshot: ResponseExample?
        var phase: Phase
    }

    // MARK: - Sorgular

    func example(_ ref: ExampleRef) -> ResponseExample? {
        request(withID: ref.requestID)?.examples.first { $0.id == ref.exampleID }
    }

    /// Açık örnek ve isteği; örnek ya da istek silinmişse `nil`.
    var openExampleContent: (request: RequestModel, example: ResponseExample)? {
        guard let ref = openExample, let request = request(withID: ref.requestID),
              let example = request.examples.first(where: { $0.id == ref.exampleID }) else { return nil }
        return (request, example)
    }

    /// Seçili isteğin son yanıtı örnek olarak kaydedilebilir mi; değilse
    /// neden (düğmenin ipucu). Yanıt yoksa ya da başarılı bir HTTP yanıtı
    /// değilse (ağ hatası, engel) düğme zaten görünmez.
    func exampleUnavailableReason(for requestID: UUID) -> ResponseExamples.CaptureError? {
        guard case .success(let display) = responses[requestID] else { return nil }
        return ResponseExamples.unavailableReason(for: display.data, isTokenFactory: isTokenFactoryRequest(requestID))
    }

    // MARK: - Görüntüleme

    /// Örneği açar. İstek seçili olur (sekmesi açılır) ama editörü yerine
    /// örnek görünür; isteğin kendisi ve canlı yanıtı olduğu gibi kalır.
    func openExample(_ ref: ExampleRef) {
        guard example(ref) != nil else { return }
        // Açılan örneğin satırı görünsün (örnekler varsayılan olarak katlı).
        expandedExampleRequestIDs.insert(ref.requestID)
        selectedRequestID = ref.requestID
        selectedRequestIDs = [ref.requestID]
        openExample = ref
    }

    /// "Dene" / ⌘↩ / örnek açıkken gelen her gönderim: istek düzenleyicisine
    /// döner ve adres alanına odaklanır. Hiçbir şey gönderilmez.
    func returnFromExample() {
        guard let ref = openExample else { return }
        openExample = nil
        if selectedRequestID != ref.requestID, request(withID: ref.requestID) != nil {
            selectedRequestID = ref.requestID
        }
        addressFocusPending = true
    }

    // MARK: - Kaydetme

    /// "Örnek olarak kaydet". Yanıt o anda alınır; sınır doluysa uyarı
    /// aşamasıyla başlar (görüntü yine alınır, silme sonrası kullanılır).
    func beginSavingExample(for requestID: UUID) {
        guard pendingExampleSave == nil,
              case .success(let display) = responses[requestID],
              exampleUnavailableReason(for: requestID) == nil,
              let request = request(withID: requestID) else { return }
        // Tutarlı görüntü: status, header, body aynı `ResponseData` değerinden.
        let data = display.data
        // Yanıtı üreten request: son BAŞARIYLA gönderilen hal (yanıt geldiğinde
        // kaydedilir). Editördeki hal o andan sonra değişmiş olabilir; yoksa
        // (ör. hiç kaydedilmemiş) güncel hal.
        let sentRequest = workspace.sentBaselines[requestID.uuidString] ?? request.withoutExamples
        pendingExampleSave = PendingExampleSave(requestID: requestID, snapshot: nil, phase: .preparing)
        let pendingID = pendingExampleSave?.id
        let existingNames = request.examples.map(\.name)
        Task { [weak self] in
            // Maskeleme body boyutuyla büyüyen regex işi: ana thread dışında.
            let captured = await BackgroundWork.run { try? ResponseExamples.capture(data, request: sentRequest, name: "") }
            guard let self, self.pendingExampleSave?.id == pendingID else { return }
            guard var snapshot = captured else {
                self.pendingExampleSave = nil
                return
            }
            snapshot.name = ResponseExamples.defaultName(statusCode: snapshot.statusCode, existing: existingNames)
            self.pendingExampleSave?.snapshot = snapshot
            self.pendingExampleSave?.phase = self.canAddExample(to: requestID) ? .naming : .limitWarning
        }
    }

    func canAddExample(to requestID: UUID) -> Bool {
        request(withID: requestID).map(ResponseExamples.canAdd) ?? false
    }

    /// Uyarıdan "Örnekleri Yönet…": görüntü korunarak ad/yönetim ekranı.
    func manageExamplesForPendingSave() {
        guard pendingExampleSave?.snapshot != nil else { return }
        pendingExampleSave?.phase = .naming
    }

    func cancelSavingExample() {
        pendingExampleSave = nil
    }

    /// Bekleyen görüntüyü verilen adla kaydeder. Bu arada sınır dolduysa
    /// hiçbir şey yazılmaz ve uyarıya dönülür (`limitReached`).
    @discardableResult
    func commitPendingExample(name: String) -> ResponseExamples.AddOutcome? {
        guard let pending = pendingExampleSave, var snapshot = pending.snapshot else { return nil }
        snapshot.name = name
        guard let outcome = withRequest(pending.requestID, { ResponseExamples.add(snapshot, to: &$0) }) else {
            // İstek bu arada silindi: kaydedilecek yer yok.
            pendingExampleSave = nil
            return nil
        }
        switch outcome {
        case .added:
            pendingExampleSave = nil
            revealExamples(of: pending.requestID)
            persist()
        case .limitReached:
            pendingExampleSave?.phase = .limitWarning
        }
        return outcome
    }

    /// Yeni örnek kenar çubuğunda görünsün: kapalı koleksiyon ve isteğin
    /// katlı örnekleri açılır.
    private func revealExamples(of requestID: UUID) {
        if let collection = collection(containing: requestID) {
            collapsedCollectionIDs.remove(collection.id)
        }
        expandedExampleRequestIDs.insert(requestID)
        sidebarRevealID = requestID
    }

    // MARK: - Düzenleme

    /// Örneği yerinde düzenlemek için bağlama (request ve response tarafı).
    /// Her yazımda `ResponseExamples.normalizedAfterEdit` uygulanır ve istek
    /// düzenlemesi gibi gecikmeli kaydedilir. Örnek ya da istek silinirse
    /// okuma son bilinen değeri döner, yazma bir şey yapmaz.
    func exampleBinding(_ ref: ExampleRef) -> Binding<ResponseExample>? {
        guard let initial = example(ref) else { return nil }
        return Binding(
            get: { self.example(ref) ?? initial },
            set: { newValue in
                // `withRequest` içinde workspace okunmaz: önceki değer önce alınır.
                guard let previous = self.example(ref) else { return }
                let normalized = ResponseExamples.normalizedAfterEdit(newValue, previous: previous)
                guard normalized != previous else { return }
                self.withRequest(ref.requestID) { request in
                    guard let index = request.examples.firstIndex(where: { $0.id == ref.exampleID }) else { return }
                    request.examples[index] = normalized
                }
                self.persistSoon()
            }
        )
    }

    // MARK: - Yönetim

    @discardableResult
    func renameExample(_ ref: ExampleRef, to name: String) -> Bool {
        let renamed = withRequest(ref.requestID) { ResponseExamples.rename(ref.exampleID, to: name, in: &$0) } ?? false
        if renamed { persist() }
        return renamed
    }

    /// Örneği siler. Açıksa istek düzenleyicisine dönülür; bekleyen kaydetme
    /// akışının görüntüsüne dokunulmaz (silme ona yer açmak için olabilir).
    func deleteExample(_ ref: ExampleRef) {
        let deleted = withRequest(ref.requestID) { ResponseExamples.delete(ref.exampleID, from: &$0) } ?? false
        guard deleted else { return }
        if openExample == ref { openExample = nil }
        persist()
    }
}
