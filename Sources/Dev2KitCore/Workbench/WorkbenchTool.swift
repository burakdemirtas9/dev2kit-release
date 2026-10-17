import Foundation

/// Workbench'teki bir araç: girdi metnini seçeneklerle işleyen saf eylemler.
///
/// Neden tek tip: biçimlendirici, kodlayıcı, dönüştürücü aynı şekle sahip
/// (metin + seçenek → metin ya da hata). Yeni araç = buraya bir tanım + test;
/// arayüz (`WorkbenchToolView`) her aracı aynı ekranla gösterir.
/// Önizleyiciler (v2 step 4) çıktısı görünüm olduğu için ayrı ele alınacak.
public struct WorkbenchTool: Identifiable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case format
        case encode
        case convert
        case preview

        /// Workbench arayüzü İngilizce (kullanıcı kararı, 2026-10-18).
        public var title: String {
            switch self {
            case .format: return "Format"
            case .encode: return "Encode / Decode"
            case .convert: return "Convert"
            case .preview: return "Preview"
            }
        }
    }

    public let id: String
    public let title: String
    public let category: Category
    /// Aramada başlığa ek olarak eşleşen kelimeler.
    public let keywords: [String]
    /// Girdi ve çıktının sözdizimi rengi.
    public let syntax: Beautifier.Kind
    public let actions: [WorkbenchAction]
    /// Girdinin doğrulaması; hata konumuyla. `nil`: doğrulama yok.
    public let validate: (@Sendable (String) -> WorkbenchValidation)?

    public init(
        id: String,
        title: String,
        category: Category,
        keywords: [String] = [],
        syntax: Beautifier.Kind,
        actions: [WorkbenchAction],
        validate: (@Sendable (String) -> WorkbenchValidation)? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.keywords = keywords
        self.syntax = syntax
        self.actions = actions
        self.validate = validate
    }

    public func action(id: String?) -> WorkbenchAction {
        actions.first { $0.id == id } ?? actions[0]
    }
}

/// Aracın bir eylemi (Biçimlendir, Sıkıştır, Escape…).
public struct WorkbenchAction: Identifiable, Sendable {
    public let id: String
    public let title: String
    /// Arayüz yalnızca eylemin kullandığı seçenekleri gösterir.
    public let usesIndentation: Bool
    public let usesSortKeys: Bool
    /// Çıktının sözdizimi rengi aracınkinden farklıysa (Escape → düz metin).
    public let outputSyntax: Beautifier.Kind?
    /// Çıktı ağaç olarak da gösterilebilir mi. Yalnızca biçimlendirmede
    /// anlamlı: sıkıştırılmış ya da kaçışlanmış metnin ağacı girdininkiyle aynı.
    public let supportsTree: Bool
    /// Çıktı elle düzenlenince girdiyi güncelleyen ters dönüşüm (iki yönlü
    /// düzenleme). Parametreler: düzenlenen çıktı, önceki girdi, seçenekler.
    /// `nil`: çıktı düzenlemesi girdiye yansımaz. Hata verirse (yazarken
    /// geçici olarak bozuk metin) girdiye dokunulmaz.
    public let reverse: (@Sendable (String, String, WorkbenchOptions) throws -> String)?
    public let run: @Sendable (String, WorkbenchOptions) throws -> String

    public init(
        id: String,
        title: String,
        usesIndentation: Bool = false,
        usesSortKeys: Bool = false,
        outputSyntax: Beautifier.Kind? = nil,
        supportsTree: Bool = false,
        reverse: (@Sendable (String, String, WorkbenchOptions) throws -> String)? = nil,
        run: @escaping @Sendable (String, WorkbenchOptions) throws -> String
    ) {
        self.id = id
        self.title = title
        self.usesIndentation = usesIndentation
        self.usesSortKeys = usesSortKeys
        self.outputSyntax = outputSyntax
        self.supportsTree = supportsTree
        self.reverse = reverse
        self.run = run
    }
}

public struct WorkbenchOptions: Hashable, Sendable {
    public var indentation: Indentation
    public var sortKeys: Bool

    public init(indentation: Indentation = .default, sortKeys: Bool = false) {
        self.indentation = indentation
        self.sortKeys = sortKeys
    }
}

/// Girinti seçimi. Varsayılan 2 boşluk: web ve Spring dünyasında en yaygını
/// (docs/V2.md "Cevaplanan sorular").
public enum Indentation: Hashable, Sendable, CaseIterable {
    case twoSpaces
    case fourSpaces
    case tab

    public static let `default` = Indentation.twoSpaces

    public var unit: String {
        switch self {
        case .twoSpaces: return "  "
        case .fourSpaces: return "    "
        case .tab: return "\t"
        }
    }

    public var title: String {
        switch self {
        case .twoSpaces: return "2 spaces"
        case .fourSpaces: return "4 spaces"
        case .tab: return "Tab"
        }
    }
}

/// Doğrulama sonucu.
public enum WorkbenchValidation: Equatable, Sendable {
    case empty
    /// Dilin gerçek okuyucusuyla doğrulandı.
    case valid
    /// Yalnızca yapısal kontrol yapıldı (parantez, tırnak, yorum dengesi);
    /// arayüz "geçerli" DEMEZ — tam sözdizimi denetlenmedi.
    case structurallyValid
    case invalid(WorkbenchIssue)
}

/// Konumlu hata. Satır ve sütun 1'den başlar; sütun karakter sayısıdır.
public struct WorkbenchIssue: Error, Equatable, Sendable, LocalizedError {
    public let message: String
    public let line: Int?
    public let column: Int?
    /// Girdideki karakter konumu (editörde işaretlemek için).
    public let offset: Int?

    public init(message: String, line: Int? = nil, column: Int? = nil, offset: Int? = nil) {
        self.message = message
        self.line = line
        self.column = column
        self.offset = offset
    }

    public var errorDescription: String? {
        guard let line, let column else { return message }
        return "\(message) (satır \(line), sütun \(column))"
    }

    /// UTF-8 bayt konumundan satır/sütun ve karakter konumu.
    static func at(offset byteOffset: Int, in bytes: [UInt8], message: String) -> WorkbenchIssue {
        let end = min(max(byteOffset, 0), bytes.count)
        let prefix = String(decoding: bytes[0..<end], as: UTF8.self)
        var line = 1
        var column = 1
        for character in prefix {
            if character.isNewline { line += 1; column = 1 } else { column += 1 }
        }
        return WorkbenchIssue(message: message, line: line, column: column, offset: prefix.utf16.count)
    }
}

/// Tüm araçlar ve arama.
public enum WorkbenchCatalog {
    public static let all: [WorkbenchTool] = [
        WorkbenchTools.json,
    ]

    public static func tool(id: String?) -> WorkbenchTool? {
        all.first { $0.id == id }
    }

    /// Başlıkta ya da anahtar kelimelerde geçenler; büyük/küçük harf ve
    /// Türkçe karakter farkı gözetmez ("json", "JSON", "biçim" → "Biçimlendir").
    public static func matching(_ query: String) -> [WorkbenchTool] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return all }
        return all.filter { tool in
            ([tool.title, tool.category.title] + tool.keywords).contains { normalized($0).contains(needle) }
        }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
    }
}

/// Araç tanımları; her dil kendi uzantısında.
public enum WorkbenchTools {}
