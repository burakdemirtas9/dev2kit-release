import Foundation

/// Uygulamanın tüm kalıcı yazımlarını sıralayan tek seri kuyruk: workspace
/// kayıtları ve geçmiş aynı sırada diske gider (iki yazıcı aynı anda diske
/// yüklenmez, kapanışta tek bekleme yeter).
public enum PersistenceQueue {
    public static let shared = DispatchQueue(label: "com.dev2kit.persistence", qos: .userInitiated)
}

/// Workspace yazımını arka plana alan SERİ yazıcı.
///
/// Neden var: `WorkspaceStore.save` tüm workspace'i encode edip diske yazıyor.
/// Bu iş MainActor'da yapılınca 100+ istekli bir workspace'te her yazımda
/// arayüz donuyordu (özellikle EDR/ağ home dizini olan makinelerde saniyelerce).
///
/// Kuyruk seri: yazımlar çağrı sırasında uygulanır, son çağrı son yazım olur.
/// Tamamlanma bildirimi main queue'ya FIFO gider; "Kaydedildi/Kaydedilemedi"
/// göstergesi bu yüzden sırayı asla şaşırmaz.
public final class WorkspaceSaver: @unchecked Sendable {
    private let store: WorkspaceStore
    private let queue: DispatchQueue

    public init(store: WorkspaceStore, label: String = "com.dev2kit.workspace-save") {
        self.store = store
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// Ortak kuyrukla: workspace ve geçmiş yazımları tek sırada (bkz.
    /// `PersistenceQueue`).
    public init(store: WorkspaceStore, queue: DispatchQueue) {
        self.store = store
        self.queue = queue
    }

    /// Anlık görüntüyü sıraya alır ve hemen döner.
    /// `snapshot` değer tipi olduğu için kuyruğa alındıktan sonra yapılan
    /// düzenlemeler bu yazımı etkilemez.
    public func save(_ snapshot: WorkspaceModel, completion: (@Sendable (Error?) -> Void)? = nil) {
        queue.async { [store] in
            var failure: Error?
            do {
                try store.save(snapshot)
            } catch {
                failure = error
            }
            guard let completion else { return }
            DispatchQueue.main.async { completion(failure) }
        }
    }

    /// Bekleyen yazımlar bitene kadar bloklar.
    /// Yalnızca veri kaybı riski olan anda çağrılır (uygulama kapanışı);
    /// normal akışta çağrılmaz, yoksa arka plana almanın anlamı kalmaz.
    public func waitForPendingWrites() {
        queue.sync { }
    }
}
