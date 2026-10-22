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
                DiagnosticLog.shared.record(DiagnosticEvent(kind: .storageSaveFailed, error: error))
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
        historyStore.waitForPendingWrites()
    }

    /// Açılış bildirimleri tek mesajda: en ağır olanı başlık, hepsi satır.
    /// Hiçbir kurtarma sessiz değil.
    static func startupMessage(for notices: [StoreNotice]) -> ResultMessage? {
        var head: (kind: MessageKind, title: String, text: String, reveal: URL?)?
        var lines: [MessageLine] = []
        func set(_ kind: MessageKind, _ title: String, _ text: String, reveal: URL?) {
            // Daha ağır olan (uyarı > bilgi) başlığı belirler.
            if head == nil || (kind == .warning && head?.kind != .warning) {
                head = (kind, title, text, reveal)
            }
        }
        for notice in notices {
            switch notice {
            case .migrated(let backup):
                set(.info, L10n.t("store.migrated.title"), L10n.t("store.migrated.message"), reveal: backup)
                lines.append(MessageLine(.info, L10n.t("store.backup", backup.path)))
            case .recoveredInterruptedSave:
                set(.info, L10n.t("store.recovered.title"), L10n.t("store.recovered.message"), reveal: nil)
            case .restoredFromBackup(let backup, let quarantine):
                set(.warning, L10n.t("store.restored.title"), L10n.t("store.restored.message"), reveal: quarantine)
                lines.append(MessageLine(.info, L10n.t("store.backup", backup.path)))
                lines.append(MessageLine(.info, L10n.t("store.quarantine", quarantine.path)))
            case .partiallyLoaded(let lost, let quarantine):
                set(.warning, L10n.t("store.partial.title"), L10n.t("store.partial.message", lost.joined(separator: ", ")), reveal: quarantine)
                lines.append(MessageLine(.info, L10n.t("store.quarantine", quarantine.path)))
            case .legacyUnreadable(let backup, let reason):
                set(.warning, L10n.t("startup.unreadable.title"), L10n.t("startup.unreadable.message"), reveal: backup)
                lines.append(MessageLine(.info, L10n.t("startup.unreadable.backup", backup.path)))
                lines.append(MessageLine(.info, L10n.t("startup.unreadable.reason", reason)))
            }
        }
        guard let head else { return nil }
        return ResultMessage(kind: head.kind, title: head.title, message: head.text, lines: lines, revealURL: head.reveal)
    }

    /// Secret deposu.
    ///
    /// Kurumsal ortamda parola, yönetici ya da erişim onayı isteyen akış YOK
    /// (kullanıcı kararı, 2026-10-21). Keychain, uygulamayı imzasıyla tanıdığı
    /// için kimliği her güncellemede değişen (ad-hoc) derlemede parola sorar.
    /// Bu yüzden:
    /// - Ekip kimlikli imza (Developer ID): Keychain; eski şifreli dosya
    ///   doğrulanarak taşınır, başarısızsa dosya yerinde kalır.
    /// - Diğer her derleme: şifreli dosya deposu (`FileSecretStore`), soru yok.
    static func defaultSecretStore() -> (SecretStore, ResultMessage?, String?) {
        guard CodeSigningStatus.hasTeamIdentity else { return (FileSecretStore(), nil, nil) }
        let keychain = KeychainSecretStore()
        let directory = AppPaths.supportDirectory
        guard SecretMigration.isPending(legacyDirectory: directory) else { return (keychain, nil, nil) }
        do {
            let report = try SecretMigration.migrate(legacyDirectory: directory, to: keychain)
            return (keychain, nil, report.map { L10n.t("secrets.migrated", String($0.migrated)) })
        } catch {
            let message = ResultMessage(
                kind: .warning,
                title: L10n.t("secrets.migrationFailed.title"),
                message: L10n.t("secrets.migrationFailed.message", error.localizedDescription)
            )
            return (FileSecretStore(), message, nil)
        }
    }

    /// Mesaja satır ekler; mesaj yoksa bilgi mesajı kurar.
    static func adding(_ line: MessageLine, to message: ResultMessage?) -> ResultMessage {
        guard let message else {
            return ResultMessage(kind: .info, title: L10n.t("store.migrated.title"), lines: [line])
        }
        return ResultMessage(kind: message.kind, title: message.title, message: message.message,
                             lines: message.lines + [line], revealURL: message.revealURL)
    }
}
