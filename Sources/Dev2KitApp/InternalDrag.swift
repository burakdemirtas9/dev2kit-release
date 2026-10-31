import AppKit
import UniformTypeIdentifiers
import Dev2KitCore

/// Uygulama içi sürükle-bırak yükü: istek, sekme ya da koleksiyon kimliği.
///
/// Neden düz metin değil (kullanıcı bildirimi, 2026-10-31): kimlik `NSString`
/// olarak taşınınca metin alanları onu yazı sanıp içine yapıştırıyordu
/// (sekme istek adının üzerine bırakılınca ad "New Request2CEC3DE6-…" oldu).
/// Bu tür metin DEĞİL: metin alanları kabul etmez; görünürlük yalnızca bu
/// süreç, kimlik başka uygulamalara da gitmez. Tür `make-app.sh`'in
/// Info.plist'inde bildirilir (`UTExportedTypeDeclarations`).
enum InternalDrag {
    static let type = UTType(exportedAs: Dev2KitIdentity.bundleIdentifier + ".internal-id", conformingTo: .data)

    static func provider(for id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    /// Bırakılan kimlik; başka türde ya da bozuksa `nil`.
    static func loadID(from provider: NSItemProvider) async -> UUID? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data.flatMap { UUID(uuidString: String(decoding: $0, as: UTF8.self)) })
            }
        }
    }
}
