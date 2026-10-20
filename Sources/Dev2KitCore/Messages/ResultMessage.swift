import Foundation

/// Kullanıcıya gösterilen mesajın türü (docs/TASARIM.md "Mesaj tipleri").
///
/// Tür içerikten ve kullanıcıdan beklenen eylemden çıkar, görünümden değil:
/// bilgi sakin ve nötr, başarı ölçülü, uyarı dikkat ister, hata gerçek bir
/// başarısızlıktır. Renk tek başına taşımaz; her türün ikonu ayrıdır.
public enum MessageKind: String, Sendable, Equatable {
    case info, success, warning, error
}

/// Mesajın bir satırı: kendi türüyle (ör. başarılı bir içe aktarmadaki uyarı).
public struct MessageLine: Equatable, Sendable {
    public let kind: MessageKind
    public let text: String

    public init(_ kind: MessageKind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    /// İçe aktarma notları düz metin; uyarı olanlar "⚠︎" ile başlar (Core'daki
    /// içe aktarıcıların ortak kuralı). İşaret metinden çıkarılır, türe
    /// dönüşür: eskiden her notun başına bir ⚠︎ daha ekleniyor, bilgi notları
    /// hata gibi görünüyordu.
    public static func note(_ note: String) -> MessageLine {
        let trimmed = note.trimmingCharacters(in: .whitespaces)
        for marker in warningMarkers where trimmed.hasPrefix(marker) {
            let text = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return MessageLine(.warning, text)
        }
        return MessageLine(.info, trimmed)
    }

    /// Uyarı notu işareti. Sıra önemli: değişken seçicili hali önce (ikisi
    /// ayrı grafem, `hasPrefix` birbirini tutmaz).
    private static let warningMarkers = ["⚠︎", "⚠"]
}

/// Bir işlemin sonucu: başlık, kısa açıklama ve türlü satırlar.
public struct ResultMessage: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let kind: MessageKind
    public let title: String
    public let message: String?
    public let lines: [MessageLine]
    /// Varsa "Finder'da Göster" düğmesi bu dosyayı gösterir.
    public let revealURL: URL?

    public init(kind: MessageKind, title: String, message: String? = nil, lines: [MessageLine] = [], revealURL: URL? = nil) {
        self.kind = kind
        self.title = title
        self.message = message
        self.lines = lines
        self.revealURL = revealURL
    }

    public static func == (lhs: ResultMessage, rhs: ResultMessage) -> Bool {
        lhs.kind == rhs.kind && lhs.title == rhs.title && lhs.message == rhs.message
            && lhs.lines == rhs.lines && lhs.revealURL == rhs.revealURL
    }

    /// Düz metin hali (ör. Postman ekranındaki satır içi özet).
    public var plainText: String {
        ([title, message].compactMap { $0 } + lines.map(\.text)).joined(separator: "\n")
    }
}

/// İçe aktarma sonucunun özeti: hangi koleksiyon eklendi, ne dışarıda kaldı.
public enum ImportResult {
    public struct Item: Sendable {
        public let name: String
        public let importedCount: Int
        public let blockedCount: Int
        public let wasRenamed: Bool
        public let notes: [String]

        public init(name: String, importedCount: Int, blockedCount: Int, wasRenamed: Bool, notes: [String]) {
            self.name = name
            self.importedCount = importedCount
            self.blockedCount = blockedCount
            self.wasRenamed = wasRenamed
            self.notes = notes
        }

        /// Tüm istekler engellendiyse koleksiyon hiç eklenmez.
        public var isRejected: Bool { importedCount == 0 && blockedCount > 0 }
    }

    /// Tür kuralı: hiçbir şey eklenmediyse hata; eklendi ama dışarıda kalan
    /// ya da uyarı notu varsa uyarı; yoksa başarı (bilgi notları türü
    /// değiştirmez).
    public static func message(for items: [Item]) -> ResultMessage {
        let accepted = items.filter { !$0.isRejected }
        var lines: [MessageLine] = []
        for item in items {
            let prefix = items.count > 1 ? "“\(item.name)”: " : ""
            if item.isRejected {
                lines.append(MessageLine(.error, prefix + L10n.t("import.result.rejected")))
                continue
            }
            if items.count > 1 {
                lines.append(MessageLine(.success, "“\(item.name)” · " + L10n.plural("import.result.requests", count: item.importedCount)))
            }
            if item.blockedCount > 0 {
                lines.append(MessageLine(.warning, prefix + L10n.plural("import.result.blocked", count: item.blockedCount)))
            }
            if item.wasRenamed {
                lines.append(MessageLine(.info, prefix + L10n.t("import.result.renamed", item.name)))
            }
            lines += item.notes.map { note in
                let line = MessageLine.note(note)
                return MessageLine(line.kind, prefix + line.text)
            }
        }

        guard !accepted.isEmpty else {
            return ResultMessage(kind: .error, title: L10n.t("result.importFailed"),
                                 message: L10n.t("import.result.allBlocked"),
                                 lines: items.count > 1 ? lines : [])
        }

        let requestCount = accepted.reduce(0) { $0 + $1.importedCount }
        let subtitle = accepted.count == 1
            ? "“\(accepted[0].name)” · " + L10n.plural("import.result.requests", count: requestCount)
            : L10n.plural("import.result.collections", count: accepted.count) + " · " + L10n.plural("import.result.requests", count: requestCount)
        let blocked = items.reduce(0) { $0 + $1.blockedCount }
        let hasProblem = lines.contains { $0.kind == .warning || $0.kind == .error }

        let title: String
        if blocked > 0 {
            title = L10n.plural("import.result.titleBlocked", count: blocked)
        } else if hasProblem {
            title = L10n.t("import.result.titleCheck")
        } else {
            title = L10n.t("import.result.title")
        }
        return ResultMessage(kind: hasProblem ? .warning : .success, title: title, message: subtitle, lines: lines)
    }
}
