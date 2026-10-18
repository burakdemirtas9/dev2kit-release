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
        case compare
        case preview

        /// Workbench arayüzü İngilizce (kullanıcı kararı, 2026-10-18).
        public var title: String {
            switch self {
            case .format: return "Format"
            case .encode: return "Encode / Decode"
            case .convert: return "Convert"
            case .compare: return "Compare"
            case .preview: return "Preview"
            }
        }
    }

    public let id: String
    public let title: String
    /// Girdinin dili ("Valid JSON"); dönüştürücüde başlıktan farklı.
    public let inputName: String
    public let category: Category
    /// Aramada başlığa ek olarak eşleşen kelimeler.
    public let keywords: [String]
    /// Girdi ve çıktının sözdizimi rengi.
    public let syntax: Beautifier.Kind
    public let actions: [WorkbenchAction]
    /// Girdinin doğrulaması; hata konumuyla. `nil`: doğrulama yok.
    public let validate: (@Sendable (String) -> WorkbenchValidation)?
    /// Yeni sekmenin seçenekleri (XML → JSON'da "Detect types" kapalı).
    public let defaultOptions: WorkbenchOptions
    /// Boş girdide soluk gösterilen örnek (API Client gövdesindeki gibi):
    /// ne yapıştırılacağı ilk bakışta anlaşılsın.
    public let sampleInput: String

    public init(
        id: String,
        title: String,
        inputName: String? = nil,
        category: Category,
        keywords: [String] = [],
        syntax: Beautifier.Kind,
        actions: [WorkbenchAction],
        validate: (@Sendable (String) -> WorkbenchValidation)? = nil,
        defaultOptions: WorkbenchOptions = WorkbenchOptions(),
        sampleInput: String = ""
    ) {
        self.sampleInput = sampleInput
        self.id = id
        self.title = title
        self.inputName = inputName ?? title
        self.defaultOptions = defaultOptions
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
    public let usesKeywordCase: Bool
    /// Dönüştürücü seçenekleri: CSV ayracı, tip algılama, XML kök adı.
    public let usesDelimiter: Bool
    public let usesDetectTypes: Bool
    public let usesRootName: Bool
    /// Kodlayıcı seçenekleri (step 2a): Base64 URL-safe, URL form kodlaması,
    /// üretim adedi (UUID), hash çıktı biçimi, HMAC anahtarı.
    public let usesURLSafe: Bool
    public let usesFormEncoding: Bool
    public let usesCount: Bool
    public let usesHashOutput: Bool
    public let usesHMACKey: Bool
    /// Boş girdide de çalışır (UUID üretme, "şu an" zaman damgası).
    public let runsOnEmptyInput: Bool
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
        usesKeywordCase: Bool = false,
        usesDelimiter: Bool = false,
        usesDetectTypes: Bool = false,
        usesRootName: Bool = false,
        usesURLSafe: Bool = false,
        usesFormEncoding: Bool = false,
        usesCount: Bool = false,
        usesHashOutput: Bool = false,
        usesHMACKey: Bool = false,
        runsOnEmptyInput: Bool = false,
        outputSyntax: Beautifier.Kind? = nil,
        supportsTree: Bool = false,
        reverse: (@Sendable (String, String, WorkbenchOptions) throws -> String)? = nil,
        run: @escaping @Sendable (String, WorkbenchOptions) throws -> String
    ) {
        self.id = id
        self.title = title
        self.usesIndentation = usesIndentation
        self.usesSortKeys = usesSortKeys
        self.usesKeywordCase = usesKeywordCase
        self.usesDelimiter = usesDelimiter
        self.usesDetectTypes = usesDetectTypes
        self.usesRootName = usesRootName
        self.usesURLSafe = usesURLSafe
        self.usesFormEncoding = usesFormEncoding
        self.usesCount = usesCount
        self.usesHashOutput = usesHashOutput
        self.usesHMACKey = usesHMACKey
        self.runsOnEmptyInput = runsOnEmptyInput
        self.outputSyntax = outputSyntax
        self.supportsTree = supportsTree
        self.reverse = reverse
        self.run = run
    }
}

public struct WorkbenchOptions: Hashable, Sendable {
    public var indentation: Indentation
    public var sortKeys: Bool
    /// SQL anahtar kelimeleri büyük harf. Varsayılan açık: en yaygın stil.
    public var uppercaseKeywords: Bool
    /// JSON → CSV ayracı.
    public var csvDelimiter: CSVDelimiter
    /// CSV/XML → JSON: `12`, `true`, boş hücre metin yerine sayı/boolean/null.
    public var detectTypes: Bool
    /// JSON → XML kök eleman adı.
    public var xmlRootName: String
    public var base64URLSafe: Bool
    /// URL kodlamada boşluk `+` (form verisi).
    public var formEncoding: Bool
    /// Üretilecek adet (UUID).
    public var generateCount: Int
    public var hashOutput: HashTool.Output
    /// HMAC anahtarı: yalnızca bellekte, sekmeyle birlikte gider.
    public var hmacKey: String

    public init(
        indentation: Indentation = .default,
        sortKeys: Bool = false,
        uppercaseKeywords: Bool = true,
        csvDelimiter: CSVDelimiter = .comma,
        detectTypes: Bool = true,
        xmlRootName: String = XMLConverter.defaultRootName,
        base64URLSafe: Bool = false,
        formEncoding: Bool = false,
        generateCount: Int = 1,
        hashOutput: HashTool.Output = .hex,
        hmacKey: String = ""
    ) {
        self.base64URLSafe = base64URLSafe
        self.formEncoding = formEncoding
        self.generateCount = generateCount
        self.hashOutput = hashOutput
        self.hmacKey = hmacKey
        self.indentation = indentation
        self.sortKeys = sortKeys
        self.uppercaseKeywords = uppercaseKeywords
        self.csvDelimiter = csvDelimiter
        self.detectTypes = detectTypes
        self.xmlRootName = xmlRootName
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

    /// Karakter dizisindeki konumdan satır/sütun ve editör konumu (UTF-16).
    /// `CodeScanner` tabanlı denetimler için.
    static func at(characterOffset: Int, in chars: [Character], message: String) -> WorkbenchIssue {
        let end = min(max(characterOffset, 0), chars.count)
        var line = 1
        var column = 1
        var utf16 = 0
        for character in chars[0..<end] {
            if character.isNewline { line += 1; column = 1 } else { column += 1 }
            utf16 += character.utf16.count
        }
        return WorkbenchIssue(message: message, line: line, column: column, offset: utf16)
    }

    /// Satır/sütundan (1 tabanlı) editör konumu. `XMLParser` gibi yalnızca
    /// satır/sütun veren okuyucular için.
    static func at(line: Int, column: Int, in text: String, message: String) -> WorkbenchIssue {
        var currentLine = 1
        var utf16 = 0
        var index = text.startIndex
        while currentLine < line, index < text.endIndex {
            if text[index].isNewline { currentLine += 1 }
            utf16 += text[index].utf16.count
            index = text.index(after: index)
        }
        var remaining = max(column - 1, 0)
        while remaining > 0, index < text.endIndex, !text[index].isNewline {
            utf16 += text[index].utf16.count
            index = text.index(after: index)
            remaining -= 1
        }
        return WorkbenchIssue(message: message, line: line, column: column, offset: utf16)
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
        WorkbenchTools.xml,
        WorkbenchTools.html,
        WorkbenchTools.css,
        WorkbenchTools.sql,
        WorkbenchTools.markdown,
        WorkbenchTools.jsonToCSV,
        WorkbenchTools.csvToJSON,
        WorkbenchTools.jsonToXML,
        WorkbenchTools.xmlToJSON,
        WorkbenchTools.jsonToYAML,
        WorkbenchTools.jwt,
        WorkbenchTools.base64,
        WorkbenchTools.url,
        WorkbenchTools.timestamp,
        WorkbenchTools.uuid,
        WorkbenchTools.hash,
        WorkbenchTools.hex,
    ]

    /// Diff Checker bir `WorkbenchTool` değil (iki girdi, kendi ekranı); kenar
    /// çubuğunda "Compare" altında kendi kimliğiyle durur.
    public static let diffCheckerID = "diff-checker"
    static let diffCheckerKeywords = ["Diff Checker", "diff", "compare", "karşılaştır", "fark"]

    public static func diffCheckerMatches(_ query: String) -> Bool {
        let needle = normalized(query)
        return needle.isEmpty || diffCheckerKeywords.contains { normalized($0).contains(needle) }
    }

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

    /// Büyük/küçük harf ve aksan farkı yok sayılır. `ı` aksanlı bir harf değil,
    /// ayrı bir harf sayıldığı için katlamada `i`'ye dönmüyor ("karsilastir"
    /// "karşılaştır"ı bulmuyordu); açıkça eşlenir.
    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i")
    }
}

/// Araç tanımları; her dil kendi uzantısında.
public enum WorkbenchTools {}
