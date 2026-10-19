import Foundation

/// JSON örneğinden sınıf/tip tanımı üretir: Java (Lombok), Kotlin data class,
/// Swift Codable, TypeScript interface/type, Python dataclass (kullanıcı
/// isteği, 2026-10-20, Workbench "Object Converter").
///
/// Kararlar (kullanıcı):
/// - Java yalnızca Lombok sınıfı (`@Data @NoArgsConstructor @AllArgsConstructor`).
/// - Alan adı JSON anahtarının KENDİSİ (camelCase'e çevrilmez). Anahtar dilde
///   geçerli bir ad olamıyorsa (`Content-Type`, `class`, `1st`) ad düzeltilir
///   ve YALNIZCA o alana eşleme eklenir; yoksa üretilen kod JSON'u okuyamaz.
/// - İç içe nesneler `Object1`, `Object2`… (genişlik öncelikli sırayla); kök
///   `Root`. Aynı yapıdaki nesneler aynı tipi paylaşır.
/// - Derinlik sınırlı (`maxDepth`): daha derin yapı hata verir.
///
/// Tip çıkarımı: dizideki nesneler birleştirilir (bazısında olmayan anahtar
/// "eksik olabilir"); `null` görülen alan "boş olabilir"; tam sayı ile ondalık
/// birleşince ondalık; uyuşmayan tipler "herhangi".
public enum ObjectCodeGenerator {
    public enum Language: String, CaseIterable, Sendable {
        case java, kotlin, swift, typeScriptInterface, typeScriptType, python
    }

    /// İç içe nesne/dizi derinliği.
    public static let maxDepth = 32
    /// Üretilecek en çok tip sayısı (devasa, her öğesi farklı veride çıktı
    /// okunmaz ve yavaşlar).
    public static let maxTypes = 500
    public static let rootName = "Root"

    public enum GenerateError: Error, LocalizedError, Equatable {
        case rootNotObject
        case tooDeep(Int)
        case tooManyTypes(Int)

        public var errorDescription: String? {
            switch self {
            case .rootNotObject:
                return "Kök bir nesne ya da nesne dizisi olmalı: sınıf yalnızca nesneden üretilir."
            case .tooDeep(let limit):
                return "İç içe derinlik \(limit)'yi aşıyor. Daha derin yapılardan sınıf üretilmez."
            case .tooManyTypes(let limit):
                return "\(limit)'den fazla farklı nesne yapısı var; çıktı okunamaz hale gelir. Daha küçük bir örnek dene."
            }
        }
    }

    public static func generate(_ input: String, language: Language) throws -> String {
        let model = try Model.build(from: try JSONDocument.parse(input))
        switch language {
        case .java: return JavaEmitter(model: model).emit()
        case .kotlin: return KotlinEmitter(model: model).emit()
        case .swift: return SwiftEmitter(model: model).emit()
        case .typeScriptInterface: return TypeScriptEmitter(model: model, asType: false).emit()
        case .typeScriptType: return TypeScriptEmitter(model: model, asType: true).emit()
        case .python: return PythonEmitter(model: model).emit()
        }
    }

    // MARK: - Şekil (örnekten çıkarılan yapı)

    indirect enum Shape: Equatable {
        case unknown          // yalnızca null ya da boş dizi görüldü
        case string
        case integer(isLong: Bool)
        case double
        case bool
        case any
        case array(Shape)
        case object(ObjectShape)
    }

    struct FieldShape: Equatable {
        let key: String
        var shape: Shape
        /// Bazı örneklerde anahtar yok.
        var isMissing: Bool
        /// Bazı örneklerde değer `null`.
        var isNullable: Bool
    }

    struct ObjectShape: Equatable {
        var fields: [FieldShape]
    }

    static func shape(of value: JSONValue, depth: Int) throws -> Shape {
        guard depth <= maxDepth else { throw GenerateError.tooDeep(maxDepth) }
        switch value {
        case .null: return .unknown
        case .string: return .string
        case .bool: return .bool
        case .number(let raw):
            if raw.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) { return .double }
            if let int = Int64(raw) { return .integer(isLong: int < Int64(Int32.min) || int > Int64(Int32.max)) }
            return .double   // Int64'e sığmayan tam sayı
        case .array(let items):
            var element = Shape.unknown
            for item in items { element = merge(element, try shape(of: item, depth: depth + 1)) }
            return .array(element)
        case .object(let members):
            var fields: [FieldShape] = []
            var index: [String: Int] = [:]
            for member in members {
                let child = try shape(of: member.value, depth: depth + 1)
                let isNull = member.value == .null
                if let existing = index[member.key] {
                    // Yinelenen anahtar: JSON'da son değer geçerli; tipleri birleştir.
                    fields[existing].shape = merge(fields[existing].shape, child)
                    fields[existing].isNullable = fields[existing].isNullable || isNull
                } else {
                    index[member.key] = fields.count
                    fields.append(FieldShape(key: member.key, shape: child, isMissing: false, isNullable: isNull))
                }
            }
            return .object(ObjectShape(fields: fields))
        }
    }

    static func merge(_ a: Shape, _ b: Shape) -> Shape {
        switch (a, b) {
        case (.unknown, let other), (let other, .unknown): return other
        case (.string, .string): return .string
        case (.bool, .bool): return .bool
        case let (.integer(x), .integer(y)): return .integer(isLong: x || y)
        case (.integer, .double), (.double, .integer), (.double, .double): return .double
        case let (.array(x), .array(y)): return .array(merge(x, y))
        case let (.object(x), .object(y)): return .object(mergeObjects(x, y))
        default: return .any
        }
    }

    static func mergeObjects(_ a: ObjectShape, _ b: ObjectShape) -> ObjectShape {
        var fields = a.fields
        var index = Dictionary(uniqueKeysWithValues: fields.enumerated().map { ($1.key, $0) })
        let keysInB = Set(b.fields.map(\.key))
        for i in fields.indices where !keysInB.contains(fields[i].key) { fields[i].isMissing = true }
        for field in b.fields {
            if let existing = index[field.key] {
                fields[existing].shape = merge(fields[existing].shape, field.shape)
                fields[existing].isMissing = fields[existing].isMissing || field.isMissing
                fields[existing].isNullable = fields[existing].isNullable || field.isNullable
            } else {
                index[field.key] = fields.count
                var added = field
                added.isMissing = true   // a'da yoktu
                fields.append(added)
            }
        }
        return ObjectShape(fields: fields)
    }

    // MARK: - Model (adlandırılmış tipler)

    indirect enum FieldType: Equatable {
        case string, integer(isLong: Bool), double, bool, any
        case array(FieldType)
        case object(String)
    }

    struct Field: Equatable {
        let key: String
        let type: FieldType
        let isMissing: Bool
        let isNullable: Bool
        var isOptional: Bool { isMissing || isNullable }
    }

    struct TypeDefinition: Equatable {
        let name: String
        let fields: [Field]
    }

    struct Model {
        /// `Root` önce, sonra `Object1`, `Object2`… (genişlik öncelikli).
        let types: [TypeDefinition]

        var usesAny: Bool { types.contains { $0.fields.contains { $0.type.containsAny } } }
        var usesList: Bool { types.contains { $0.fields.contains { $0.type.containsArray } } }

        static func build(from value: JSONValue) throws -> Model {
            let rootShape: ObjectShape
            switch try ObjectCodeGenerator.shape(of: value, depth: 0) {
            case .object(let object): rootShape = object
            case .array(let element):
                guard case .object(let object) = element else { throw GenerateError.rootNotObject }
                rootShape = object
            default:
                throw GenerateError.rootNotObject
            }

            var named: [(shape: ObjectShape, name: String)] = [(rootShape, ObjectCodeGenerator.rootName)]
            var queue: [ObjectShape] = [rootShape]
            var types: [TypeDefinition] = []
            var counter = 0

            func name(for object: ObjectShape) throws -> String {
                if let existing = named.first(where: { $0.shape == object }) { return existing.name }
                counter += 1
                guard counter < maxTypes else { throw GenerateError.tooManyTypes(maxTypes) }
                let name = "Object\(counter)"
                named.append((object, name))
                queue.append(object)
                return name
            }

            func type(of shape: Shape) throws -> FieldType {
                switch shape {
                case .unknown, .any: return .any
                case .string: return .string
                case .integer(let isLong): return .integer(isLong: isLong)
                case .double: return .double
                case .bool: return .bool
                case .array(let element): return .array(try type(of: element))
                case .object(let object): return .object(try name(for: object))
                }
            }

            var position = 0
            while position < queue.count {
                let object = queue[position]
                position += 1
                let typeName = named.first(where: { $0.shape == object })?.name ?? ObjectCodeGenerator.rootName
                let fields = try object.fields.map { field in
                    Field(key: field.key, type: try type(of: field.shape),
                          isMissing: field.isMissing,
                          isNullable: field.isNullable || field.shape == .unknown)
                }
                types.append(TypeDefinition(name: typeName, fields: fields))
            }
            return Model(types: types)
        }
    }

    // MARK: - Ad düzeltme

    /// Dilde geçerli ad: geçersiz karakter `_`, rakamla başlıyorsa `_` öneki,
    /// ayrılmış kelimeye `_` soneki. Aynı tipte çakışan adlar numaralanır.
    static func identifiers(for keys: [String], reserved: Set<String>) -> [String] {
        var used: Set<String> = []
        return keys.map { key in
            var name = String(key.map { $0 == "_" || $0.isLetter || $0.isNumber ? $0 : "_" })
            if name.isEmpty { name = "_" }
            if let first = name.first, first.isNumber { name = "_" + name }
            if reserved.contains(name) { name += "_" }
            var unique = name
            var suffix = 2
            while used.contains(unique) { unique = "\(name)\(suffix)"; suffix += 1 }
            used.insert(unique)
            return unique
        }
    }
}

extension ObjectCodeGenerator.FieldType {
    var containsAny: Bool {
        switch self {
        case .any: return true
        case .array(let element): return element.containsAny
        default: return false
        }
    }

    var containsArray: Bool {
        if case .array = self { return true }
        return false
    }
}

// MARK: - Java (Lombok)

private struct JavaEmitter {
    let model: ObjectCodeGenerator.Model

    static let reserved: Set<String> = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const",
        "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float",
        "for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long", "native",
        "new", "package", "private", "protected", "public", "return", "short", "static", "strictfp",
        "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "void",
        "volatile", "while", "true", "false", "null", "var", "record", "yield", "_",
    ]

    func type(_ type: ObjectCodeGenerator.FieldType) -> String {
        switch type {
        case .string: return "String"
        case .integer(let isLong): return isLong ? "Long" : "Integer"
        case .double: return "Double"
        case .bool: return "Boolean"
        case .any: return "Object"
        case .array(let element): return "List<\(self.type(element))>"
        case .object(let name): return name
        }
    }

    func emit() -> String {
        var body: [String] = []
        var needsJsonProperty = false
        for (index, definition) in model.types.enumerated() {
            let isRoot = index == 0
            let pad = isRoot ? "" : "    "
            var lines = ["@Data", "@NoArgsConstructor", "@AllArgsConstructor",
                         isRoot ? "public class \(definition.name) {" : "public static class \(definition.name) {"]
            let names = ObjectCodeGenerator.identifiers(for: definition.fields.map(\.key), reserved: Self.reserved)
            for (field, name) in zip(definition.fields, names) {
                if name != field.key {
                    needsJsonProperty = true
                    lines.append("    @JsonProperty(\(JSONValue.quoted(field.key)))")
                }
                lines.append("    private \(type(field.type)) \(name);")
            }
            if isRoot {
                body += lines
            } else {
                body.append("")
                body += lines.map { pad + $0 }
                body.append(pad + "}")
            }
        }
        body.append("}")

        var imports: [String] = []
        if needsJsonProperty { imports.append("import com.fasterxml.jackson.annotation.JsonProperty;") }
        if model.usesList { imports.append("import java.util.List;") }
        imports += ["import lombok.AllArgsConstructor;", "import lombok.Data;", "import lombok.NoArgsConstructor;"]
        return (imports + [""] + body).joined(separator: "\n")
    }
}

// MARK: - Kotlin

private struct KotlinEmitter {
    let model: ObjectCodeGenerator.Model

    static let reserved: Set<String> = [
        "as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in",
        "interface", "is", "null", "object", "package", "return", "super", "this", "throw", "true",
        "try", "typealias", "typeof", "val", "var", "when", "while", "_",
    ]

    func type(_ type: ObjectCodeGenerator.FieldType) -> String {
        switch type {
        case .string: return "String"
        case .integer(let isLong): return isLong ? "Long" : "Int"
        case .double: return "Double"
        case .bool: return "Boolean"
        case .any: return "Any"
        case .array(let element): return "List<\(self.type(element))>"
        case .object(let name): return name
        }
    }

    func emit() -> String {
        var lines: [String] = []
        var needsJsonProperty = false
        for definition in model.types {
            if !lines.isEmpty { lines.append("") }
            let names = ObjectCodeGenerator.identifiers(for: definition.fields.map(\.key), reserved: Self.reserved)
            if definition.fields.isEmpty {
                lines.append("class \(definition.name)")
                continue
            }
            lines.append("data class \(definition.name)(")
            for (field, name) in zip(definition.fields, names) {
                var annotation = ""
                if name != field.key {
                    needsJsonProperty = true
                    annotation = "@JsonProperty(\(JSONValue.quoted(field.key))) "
                }
                let declared = type(field.type) + (field.isOptional ? "? = null" : "")
                lines.append("    \(annotation)val \(name): \(declared),")
            }
            lines.append(")")
        }
        let imports = needsJsonProperty ? ["import com.fasterxml.jackson.annotation.JsonProperty", ""] : []
        return (imports + lines).joined(separator: "\n")
    }
}

// MARK: - Swift Codable

private struct SwiftEmitter {
    let model: ObjectCodeGenerator.Model

    static let reserved: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
        "init", "inout", "internal", "let", "open", "operator", "private", "protocol", "public",
        "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "continue",
        "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat",
        "return", "switch", "where", "while", "as", "Any", "catch", "false", "is", "nil", "super",
        "self", "Self", "throw", "throws", "true", "try", "_",
    ]

    func type(_ type: ObjectCodeGenerator.FieldType) -> String {
        switch type {
        case .string: return "String"
        case .integer: return "Int"
        case .double: return "Double"
        case .bool: return "Bool"
        case .any: return "JSONValue"
        case .array(let element): return "[\(self.type(element))]"
        case .object(let name): return name
        }
    }

    func emit() -> String {
        var lines: [String] = []
        for definition in model.types {
            if !lines.isEmpty { lines.append("") }
            let names = ObjectCodeGenerator.identifiers(for: definition.fields.map(\.key), reserved: [])
            lines.append("struct \(definition.name): Codable {")
            var needsKeys = false
            for (field, name) in zip(definition.fields, names) {
                if name != field.key { needsKeys = true }
                // Ayrılmış kelime Swift'te ters tırnakla ad olabilir; eşleme gerekmez.
                let declared = Self.reserved.contains(name) ? "`\(name)`" : name
                lines.append("    let \(declared): \(type(field.type))\(field.isOptional ? "?" : "")")
            }
            if needsKeys {
                lines.append("")
                lines.append("    enum CodingKeys: String, CodingKey {")
                for (field, name) in zip(definition.fields, names) {
                    let declared = Self.reserved.contains(name) ? "`\(name)`" : name
                    lines.append(name == field.key
                                 ? "        case \(declared)"
                                 : "        case \(declared) = \(JSONValue.quoted(field.key))")
                }
                lines.append("    }")
            }
            lines.append("}")
        }
        if model.usesAny { lines += [""] + Self.jsonValueHelper }
        return lines.joined(separator: "\n")
    }

    /// Tipi belirsiz alan için (karışık ya da yalnızca `null` görülen):
    /// Codable `Any` çözemiyor.
    static let jsonValueHelper = [
        "/// Tipi örnekten çıkarılamayan değer.",
        "enum JSONValue: Codable {",
        "    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null",
        "",
        "    init(from decoder: Decoder) throws {",
        "        let container = try decoder.singleValueContainer()",
        "        if container.decodeNil() { self = .null }",
        "        else if let value = try? container.decode(Bool.self) { self = .bool(value) }",
        "        else if let value = try? container.decode(Double.self) { self = .number(value) }",
        "        else if let value = try? container.decode(String.self) { self = .string(value) }",
        "        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }",
        "        else { self = .object(try container.decode([String: JSONValue].self)) }",
        "    }",
        "",
        "    func encode(to encoder: Encoder) throws {",
        "        var container = encoder.singleValueContainer()",
        "        switch self {",
        "        case .string(let value): try container.encode(value)",
        "        case .number(let value): try container.encode(value)",
        "        case .bool(let value): try container.encode(value)",
        "        case .object(let value): try container.encode(value)",
        "        case .array(let value): try container.encode(value)",
        "        case .null: try container.encodeNil()",
        "        }",
        "    }",
        "}",
    ]
}

// MARK: - TypeScript

private struct TypeScriptEmitter {
    let model: ObjectCodeGenerator.Model
    let asType: Bool

    func type(_ type: ObjectCodeGenerator.FieldType) -> String {
        switch type {
        case .string: return "string"
        case .integer, .double: return "number"
        case .bool: return "boolean"
        case .any: return "unknown"
        case .array(let element): return "\(self.type(element))[]"
        case .object(let name): return name
        }
    }

    /// TypeScript'te özellik adı tırnaklı da olabilir: anahtar olduğu gibi kalır.
    func property(_ key: String) -> String {
        guard let first = key.first, first == "_" || first == "$" || first.isLetter,
              key.allSatisfy({ $0 == "_" || $0 == "$" || $0.isLetter || $0.isNumber }) else {
            return JSONValue.quoted(key)
        }
        return key
    }

    func emit() -> String {
        var lines: [String] = []
        for definition in model.types {
            if !lines.isEmpty { lines.append("") }
            lines.append(asType ? "export type \(definition.name) = {" : "export interface \(definition.name) {")
            for field in definition.fields {
                let optional = field.isMissing ? "?" : ""
                let nullable = field.isNullable && field.type != .any ? " | null" : ""
                lines.append("  \(property(field.key))\(optional): \(type(field.type))\(nullable);")
            }
            lines.append(asType ? "};" : "}")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Python dataclass

private struct PythonEmitter {
    let model: ObjectCodeGenerator.Model

    static let reserved: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class",
        "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global",
        "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return",
        "try", "while", "with", "yield",
    ]

    func type(_ type: ObjectCodeGenerator.FieldType) -> String {
        switch type {
        case .string: return "str"
        case .integer: return "int"
        case .double: return "float"
        case .bool: return "bool"
        case .any: return "Any"
        case .array(let element): return "List[\(self.type(element))]"
        case .object(let name): return name
        }
    }

    func emit() -> String {
        var typing = ["List", "Optional"].filter { name in
            name == "List" ? model.usesList : model.types.contains { $0.fields.contains(where: \.isOptional) }
        }
        if model.usesAny { typing.insert("Any", at: 0) }
        var lines = ["from __future__ import annotations", "", "from dataclasses import dataclass"]
        if !typing.isEmpty { lines.append("from typing import \(typing.joined(separator: ", "))") }
        for definition in model.types {
            lines += ["", "", "@dataclass", "class \(definition.name):"]
            let names = ObjectCodeGenerator.identifiers(for: definition.fields.map(\.key), reserved: Self.reserved)
            let pairs = Array(zip(definition.fields, names))
            // Varsayılanı olan alanlar sonda olmalı (dataclass kuralı).
            let ordered = pairs.filter { !$0.0.isOptional } + pairs.filter { $0.0.isOptional }
            if ordered.isEmpty { lines.append("    pass") }
            for (field, name) in ordered {
                let note = name == field.key ? "" : "  # JSON: \(JSONValue.quoted(field.key))"
                if field.isOptional {
                    lines.append("    \(name): Optional[\(type(field.type))] = None\(note)")
                } else {
                    lines.append("    \(name): \(type(field.type))\(note)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
