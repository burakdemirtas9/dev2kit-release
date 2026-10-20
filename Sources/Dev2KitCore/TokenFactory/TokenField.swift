import Foundation

/// Token servisinin yanıt gövdesinden token alanını çıkarır.
///
/// Yol sözdizimi bilerek küçük: nokta ile alan, köşeli parantez ile dizi
/// indisi (`data.token`, `items[0].jwt`). JSONPath'in tamamı (filtre,
/// joker) burada gereksiz; yanlış alanın sessizce seçilmesine yol açar.
public enum TokenField {
    public enum Failure: Error, Equatable, LocalizedError {
        case emptyPath
        case invalidPath(String)
        case notJSON
        /// Yolun bu parçası yanıtta yok.
        case missing(path: String)
        /// Alan var ama metin değil (nesne, dizi, null…).
        case notText(path: String)
        case empty(path: String)

        public var errorDescription: String? {
            switch self {
            case .emptyPath: return L10n.t("tokenField.emptyPath")
            case .invalidPath(let path): return L10n.t("tokenField.invalidPath", path)
            case .notJSON: return L10n.t("tokenField.notJSON")
            case .missing(let path): return L10n.t("tokenField.missing", path)
            case .notText(let path): return L10n.t("tokenField.notText", path)
            case .empty(let path): return L10n.t("tokenField.empty", path)
            }
        }
    }

    enum Step: Equatable {
        case key(String)
        case index(Int)
    }

    /// `data.items[0].token` → [key(data), key(items), index(0), key(token)]
    static func steps(of path: String) throws -> [Step] {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw Failure.emptyPath }
        var steps: [Step] = []
        for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            var rest = Substring(part)
            // Parantezden önceki ad (dizi doğrudan kökteyse boş olabilir).
            let name = rest.prefix { $0 != "[" }
            if !name.isEmpty { steps.append(.key(String(name))) }
            rest = rest.dropFirst(name.count)
            while !rest.isEmpty {
                guard rest.first == "[", let close = rest.firstIndex(of: "]"),
                      let index = Int(rest[rest.index(after: rest.startIndex)..<close]), index >= 0
                else { throw Failure.invalidPath(trimmed) }
                steps.append(.index(index))
                rest = rest[rest.index(after: close)...]
            }
            if name.isEmpty && part.isEmpty { throw Failure.invalidPath(trimmed) }
        }
        guard !steps.isEmpty else { throw Failure.invalidPath(trimmed) }
        return steps
    }

    /// Gövdeyi çözer ve alanın metin değerini döner.
    ///
    /// Sayı ya da mantıksal değer metne ÇEVRİLMEZ: token olarak `12` gelmesi
    /// büyük ihtimalle yanlış alan seçildiğini gösterir; sessizce kabul etmek
    /// hatayı isteği atan servise taşır.
    public static func value(at path: String, in body: Data) throws -> String {
        let steps = try steps(of: path)
        guard let root = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            throw Failure.notJSON
        }
        var current: Any = root
        var walked = ""
        for step in steps {
            switch step {
            case .key(let key):
                walked += walked.isEmpty ? key : ".\(key)"
                guard let object = current as? [String: Any], let next = object[key] else {
                    throw Failure.missing(path: walked)
                }
                current = next
            case .index(let index):
                walked += "[\(index)]"
                guard let array = current as? [Any], array.indices.contains(index) else {
                    throw Failure.missing(path: walked)
                }
                current = array[index]
            }
        }
        guard let text = current as? String else { throw Failure.notText(path: walked) }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw Failure.empty(path: walked) }
        return value
    }
}
