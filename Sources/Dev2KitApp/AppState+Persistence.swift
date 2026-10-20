import Foundation
import Dev2KitCore

// Workspace'in diske yazılması. İki yol var: yapısal değişiklik `persist()`
// ile hemen kuyruğa, metin düzenlemesi `persistSoon()` ile 400 ms sonra.
// Yazımın kendisi arka planda (`WorkspaceSaver`); neden senkron olmadığı
// TODO.md "Bilinçli olarak yapılmayanlar"da ölçümüyle yazılı.

extension AppState {
    /// Otomatik kaydın görünür hali. Görünmeyen kayıt, kaydetmemek kadar
    /// güvensizlik yaratıyor — kullanıcı ne olduğunu bilmeli.
    enum SaveState: Equatable {
        case idle
        case pending
        case saved(Date)
        case failed(String)
    }

    /// Yapısal değişiklikler (ekle/sil/sırala/içe aktar) için anında yazım.
    func persist() {
        pruneTabs()
        dropStaleTokens()
        persistTask?.cancel()
        persistTask = nil
        writeWorkspace()
    }

    /// Metin düzenlemesi için geciktirilmiş yazım.
    ///
    /// Workspace TEK dosyaya pretty-printed JSON olarak, atomik (temp + rename)
    /// yazılıyor. Her tuş vuruşunda bunu yapmak tüm koleksiyonları yeniden
    /// encode edip main thread'de diske basmak demekti — yazarken takılmanın
    /// ana sebebi buydu. Yazım durduktan 400ms sonra tek sefer yazılır.
    func persistSoon() {
        dropStaleTokens()
        saveState = .pending
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.writeWorkspace()
        }
    }

    /// Bekleyen yazımı hemen tamamlar (istek gönderme, pencere kapanışı gibi
    /// veri kaybı riski olan anlarda çağrılır).
    func flushPendingWrites() {
        guard persistTask != nil else { return }
        persist()
    }

    private func writeWorkspace() {
        persistTask = nil
        guard !persistenceBlocked else {
            saveState = .failed(L10n.t("save.blocked"))
            return
        }
        // Encode + disk yazımı arka planda; MainActor yalnızca sonucu işler.
        saver.save(workspace) { error in
            MainActor.assumeIsolated {
                guard let error else {
                    self.saveError = nil
                    self.saveState = .saved(Date())
                    return
                }
                self.saveError = L10n.t("save.writeFailed", error.localizedDescription)
                self.saveState = .failed(error.localizedDescription)
            }
        }
    }

    /// Bekleyen yazımı başlatıp bitmesini bekler.
    /// Yalnızca uygulama kapanışında çağrılır: kapanırken yarım kalan yazım
    /// veri kaybı demektir. Normal akışta `flushPendingWrites()` yeterlidir.
    func waitForPendingWrites() {
        flushPendingWrites()
        saver.waitForPendingWrites()
    }
}
