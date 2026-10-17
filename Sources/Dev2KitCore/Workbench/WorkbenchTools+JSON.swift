import Foundation

extension WorkbenchTools {
    /// JSON: doğrula, biçimlendir (girinti, anahtar sıralama), sıkıştır,
    /// escape / unescape. Ağaç görünümü arayüzde (`JSONTreeNode`).
    public static let json = WorkbenchTool(
        id: "json",
        title: "JSON",
        category: .format,
        keywords: ["beautify", "pretty", "minify", "validate", "tree", "biçimlendir", "sıkıştır", "doğrula", "ağaç"],
        syntax: .json,
        actions: [
            // Biçim ve sıkıştırmada veri aynı: düzenlenen çıktı olduğu gibi girdi olur.
            WorkbenchAction(id: "format", title: "Format", usesIndentation: true, usesSortKeys: true, supportsTree: true,
                            reverse: { output, _, _ in output }) { input, options in
                try JSONTool.format(input, options: options)
            },
            WorkbenchAction(id: "minify", title: "Minify", usesSortKeys: true,
                            reverse: { output, _, _ in output }) { input, options in
                try JSONTool.minify(input, sortKeys: options.sortKeys)
            },
            WorkbenchAction(id: "escape", title: "Escape", outputSyntax: .plain,
                            reverse: { output, _, _ in try JSONTool.decodeLiteral(output) }) { input, _ in
                JSONTool.escape(input)
            },
            WorkbenchAction(id: "unescape", title: "Unescape", usesIndentation: true,
                            reverse: { output, previous, _ in JSONTool.reverseUnescape(output, previousInput: previous) }) { input, options in
                try JSONTool.unescape(input, options: options)
            },
        ],
        validate: { JSONTool.validate($0) }
    )
}

/// JSON aracının kuralları (saf, testli).
public enum JSONTool {
    public static func validate(_ input: String) -> WorkbenchValidation {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        do {
            _ = try JSONDocument.parse(input)
            return .valid
        } catch let issue as WorkbenchIssue {
            return .invalid(issue)
        } catch {
            return .invalid(WorkbenchIssue(message: error.localizedDescription))
        }
    }

    /// Girintili biçim. Sıralama kapalıyken mevcut `JSONFormatter` kullanılır
    /// (yorumlar yerinde kalır, API Client'taki Beautify ile aynı çıktı).
    /// Sıralama açıkken değer yeniden yazılır; yorumlar bu yüzden düşer.
    public static func format(_ input: String, options: WorkbenchOptions) throws -> String {
        let value = try JSONDocument.parse(input)
        if options.sortKeys {
            return try JSONFormatter.beautify(value.compact(sortKeys: true), indent: options.indentation.unit)
        }
        return try JSONFormatter.beautify(input, indent: options.indentation.unit)
    }

    /// Tek satır; yorumlar ve gereksiz boşluk atılır, sayılar aynen kalır.
    public static func minify(_ input: String, sortKeys: Bool) throws -> String {
        try JSONDocument.parse(input).compact(sortKeys: sortKeys)
    }

    /// Metni JSON string literaline çevirir: başka bir JSON'un içine
    /// gömülecek gövde, log mesajı vb.
    public static func escape(_ input: String) -> String {
        JSONValue.quoted(input)
    }

    /// Unescape çıktısının tersi. Girdi zaten kaçışsız JSON'du ise Unescape
    /// yalnızca biçimlendirmişti (`unescape`): ters yön de olduğu gibi döner.
    /// Aksi halde girdi kaçışlı bir string'di: düzenleme yeniden kaçışlanır.
    public static func reverseUnescape(_ output: String, previousInput: String) -> String {
        let trimmed = previousInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasQuoted = trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2
        if !wasQuoted, case .valid = validate(trimmed) { return output }
        return escape(output)
    }

    /// Ağaçta düzenlenen değeri girdiye yazar; sonuç seçilen girintiyle
    /// biçimlendirilir (yorumlar düşer — değer yeniden yazılıyor).
    ///
    /// Yazılan metnin tipi: düğüm string ise her zaman string (tırnak
    /// gerekmez); değilse JSON yazımı denenir (`12`, `true`, `null`,
    /// `"metin"`), olmazsa string kabul edilir.
    public static func replacingValue(
        in input: String,
        at steps: [JSONPathStep],
        with text: String,
        options: WorkbenchOptions
    ) throws -> String {
        let root = try JSONDocument.parse(input)
        guard let current = root.value(at: steps) else {
            throw WorkbenchIssue(message: "Düzenlenen değer girdide artık yok")
        }
        let newValue: JSONValue
        if case .string = current {
            newValue = .string(text)
        } else if let parsed = try? JSONDocument.parse(text), !parsed.isContainer {
            newValue = parsed
        } else {
            newValue = .string(text)
        }
        let updated = try root.replacing(at: steps, with: newValue)
        return try JSONFormatter.beautify(updated.compact(sortKeys: options.sortKeys), indent: options.indentation.unit)
    }

    /// Escape çıktısının tersi: tırnaklı JSON string literalini çözer, başka
    /// hiçbir şey yapmaz (biçimlendirmez). Literal değilse hata.
    public static func decodeLiteral(_ literal: String) throws -> String {
        guard case .string(let text) = try JSONDocument.parse(literal) else {
            throw WorkbenchIssue(message: "Unescape: metin bir JSON string değil")
        }
        return text
    }

    /// Kaçışlı metni çözer. Kibana/kuyruk loglarındaki iç içe JSON
    /// (`"{\"a\":1}"`) sık görüldüğü için: çözülen metin JSON'sa
    /// biçimlendirilmiş döner.
    ///
    /// Girdi tırnaklı (`"…"`) ya da tırnaksız (`{\"a\":1}`) olabilir. Girdi
    /// zaten kaçışsız JSON'sa (nesne, dizi…) çözülecek bir şey yoktur; hata
    /// yerine biçimlendirilmiş hali döner. Önceden tırnağa sarılıp ilk `"`'de
    /// biten bir string sanılıyor, "değerden sonra beklenmeyen içerik" gibi
    /// anlamsız bir hata çıkıyordu.
    public static func unescape(_ input: String, options: WorkbenchOptions) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkbenchIssue(message: "Unescape: içerik boş") }
        let isQuoted = trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2
        if !isQuoted, case .valid = validate(trimmed) {
            return try format(trimmed, options: options)
        }
        let literal = isQuoted ? trimmed : "\"" + trimmed.replacingOccurrences(of: "\n", with: "\\n") + "\""
        let decoded: String
        do {
            guard case .string(let text) = try JSONDocument.parse(literal) else {
                throw WorkbenchIssue(message: "Unescape: metin bir JSON string değil")
            }
            decoded = text
        } catch let issue as WorkbenchIssue {
            // Tırnaksız girdide konum, eklenen tırnak yüzünden bir kayık olur;
            // sebebi açıkça söylemek konumdan daha yararlı.
            let reason = issue.message.replacingOccurrences(of: "Geçersiz JSON: ", with: "")
            throw WorkbenchIssue(message: "Unescape: metin kaçışlı bir JSON string değil (\(reason)). Kaçışsız tırnak (\") içeriyor olabilir.")
        }
        if case .valid = validate(decoded) {
            return try format(decoded, options: options)
        }
        return decoded
    }
}

/// Ağaç görünümünün düğümü. Çocuklar ERİŞİLİNCE hesaplanır: büyük JSON'da
/// açılmamış dalların düğümleri hiç oluşmaz (bellek, docs/V2.md).
public struct JSONTreeNode: Identifiable, Sendable {
    /// Çok elemanlı dizilerde gösterilen üst sınır; kalanı tek satırda özetlenir.
    public static let childLimit = 1_000

    /// Yol: Token Factory'nin "yanıttaki alan" sözdizimiyle aynı
    /// (`data.items[0].token`) — kopyalanıp doğrudan oraya yapıştırılabilir.
    public let id: String
    public let label: String
    public let value: JSONValue
    /// Kökten bu düğüme adımlar; değer düzenlemede düğümü bulmak için.
    /// (Yol metni `["a.b"]` gibi biçimleri okunur kılmak için var; buna dayanılmaz.)
    public let steps: [JSONPathStep]
    /// Gösterilmeyen kardeş sayısı (yalnızca özet satırında).
    public let hiddenSiblings: Int

    public init(value: JSONValue) {
        self.init(id: "", label: "kök", value: value, steps: [], hiddenSiblings: 0)
    }

    init(id: String, label: String, value: JSONValue, steps: [JSONPathStep], hiddenSiblings: Int) {
        self.id = id
        self.label = label
        self.value = value
        self.steps = steps
        self.hiddenSiblings = hiddenSiblings
    }

    /// Yaprak (metin, sayı, true/false, null) mı — yalnızca bunlar düzenlenir.
    public var isEditableLeaf: Bool {
        guard hiddenSiblings == 0 else { return false }
        switch value {
        case .object, .array: return false
        default: return true
        }
    }

    /// Düzenleme kutusunda gösterilecek metin: string tırnaksız, diğerleri JSON yazımıyla.
    public var editableText: String {
        if case .string(let text) = value { return text }
        return value.compact()
    }

    public var path: String { id }

    /// Kısa önizleme: değerin kendisi ya da `{3}` / `[12]`.
    public var summary: String {
        if hiddenSiblings > 0 { return "… \(hiddenSiblings) eleman daha" }
        switch value {
        case .object(let members): return "{\(members.count)}"
        case .array(let items): return "[\(items.count)]"
        case .string(let text): return JSONValue.quoted(text)
        case .number(let raw): return raw
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        }
    }

    public var children: [JSONTreeNode]? {
        guard hiddenSiblings == 0 else { return nil }
        switch value {
        case .object(let members):
            return members.map {
                JSONTreeNode(id: Self.join(id, key: $0.key), label: $0.key, value: $0.value,
                             steps: steps + [.key($0.key)], hiddenSiblings: 0)
            }
        case .array(let items):
            var nodes = items.prefix(Self.childLimit).enumerated().map {
                JSONTreeNode(id: "\(id)[\($0.offset)]", label: "[\($0.offset)]", value: $0.element,
                             steps: steps + [.index($0.offset)], hiddenSiblings: 0)
            }
            if items.count > Self.childLimit {
                nodes.append(JSONTreeNode(id: "\(id)[…]", label: "", value: .null, steps: steps,
                                          hiddenSiblings: items.count - Self.childLimit))
            }
            return nodes
        default:
            return nil
        }
    }

    /// Anahtarı yola ekler. Nokta ya da köşeli parantez içeren anahtar
    /// Token Factory sözdiziminde yazılamaz; okunur kalsın diye
    /// `["a.b"]` biçiminde eklenir.
    static func join(_ path: String, key: String) -> String {
        if key.contains(".") || key.contains("[") || key.contains("]") || key.isEmpty {
            return "\(path)[\(JSONValue.quoted(key))]"
        }
        return path.isEmpty ? key : "\(path).\(key)"
    }
}

/// JSON içinde bir adım: nesne anahtarı ya da dizi indisi.
public enum JSONPathStep: Hashable, Sendable {
    case key(String)
    case index(Int)
}

public extension JSONValue {
    var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }

    /// Adımların gösterdiği değer; yoksa `nil`. Yinelenen anahtarda ilki.
    func value(at steps: [JSONPathStep]) -> JSONValue? {
        guard let step = steps.first else { return self }
        switch (self, step) {
        case (.object(let members), .key(let key)):
            return members.first { $0.key == key }?.value.value(at: Array(steps.dropFirst()))
        case (.array(let items), .index(let index)) where items.indices.contains(index):
            return items[index].value(at: Array(steps.dropFirst()))
        default:
            return nil
        }
    }

    /// Adımların gösterdiği değeri değiştirir; sıra ve diğer her şey korunur.
    func replacing(at steps: [JSONPathStep], with newValue: JSONValue) throws -> JSONValue {
        guard let step = steps.first else { return newValue }
        let rest = Array(steps.dropFirst())
        switch (self, step) {
        case (.object(var members), .key(let key)):
            guard let index = members.firstIndex(where: { $0.key == key }) else { break }
            members[index].value = try members[index].value.replacing(at: rest, with: newValue)
            return .object(members)
        case (.array(var items), .index(let index)) where items.indices.contains(index):
            items[index] = try items[index].replacing(at: rest, with: newValue)
            return .array(items)
        default:
            break
        }
        throw WorkbenchIssue(message: "Düzenlenen değer girdide artık yok")
    }
}
