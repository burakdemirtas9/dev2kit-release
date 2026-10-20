import Foundation

/// Header / query / form alanlarının "toplu düzenleme" metin biçimi.
///
/// Postman'deki Bulk Edit ile aynı sözdizimi:
///   `Anahtar: değer`  — her satır bir alan
///   `//Anahtar: değer` — devre dışı alan
/// Boş satırlar yok sayılır. Değer içindeki `:` korunur (ilk `:` böler).
public enum KeyValueBulkCoder {
    public struct Issue: Equatable, Sendable {
        public let line: Int
        public let message: String
    }

    public struct ValidationError: Error, LocalizedError, Equatable {
        public let issues: [Issue]

        public var errorDescription: String? {
            issues
                .prefix(3)
                .map { L10n.t("bulk.line", L10n.number($0.line), $0.message) }
                .joined(separator: " · ")
        }
    }

    private static let disabledPrefix = "//"

    public static func encode(_ entries: [KeyValueEntry]) -> String {
        entries
            .filter { !($0.key.isEmpty && $0.value.isEmpty) }
            .map { entry in
                let prefix = entry.enabled ? "" : disabledPrefix
                return "\(prefix)\(entry.key): \(entry.value)"
            }
            .joined(separator: "\n")
    }

    /// Yazarken yarım kalan satırları (henüz `:` yazılmamış) atlayarak çözer.
    /// Toplu modda her tuş vuruşunda çağrıldığı için hata fırlatmaz.
    public static func decode(_ text: String) -> [KeyValueEntry] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            guard let parsed = parse(String(rawLine)) else { return nil }
            return KeyValueEntry(key: parsed.key, value: parsed.value, enabled: parsed.enabled)
        }
    }

    /// Toplu metni denetler: `:` içermeyen satırlar ve boş anahtarlar sorun sayılır.
    public static func validate(_ text: String) -> [Issue] {
        var issues: [Issue] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            var body = line
            if body.hasPrefix(disabledPrefix) {
                body = String(body.dropFirst(disabledPrefix.count))
            }
            guard let separator = body.firstIndex(of: ":") else {
                issues.append(Issue(line: index + 1, message: L10n.t("bulk.noColon")))
                continue
            }
            if body[body.startIndex..<separator].trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(Issue(line: index + 1, message: L10n.t("bulk.emptyKey")))
            }
        }
        return issues
    }

    /// Alan listesindeki mantık hataları (toplu moda girmeden de denetlenir).
    public static func validate(entries: [KeyValueEntry]) -> [Issue] {
        var issues: [Issue] = []
        var seen: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            let line = index + 1
            let key = entry.key.trimmingCharacters(in: .whitespaces)
            if key.isEmpty {
                if !entry.value.isEmpty {
                    issues.append(Issue(line: line, message: L10n.t("bulk.valueWithoutKey")))
                }
                continue
            }
            if key.rangeOfCharacter(from: .whitespaces) != nil {
                issues.append(Issue(line: line, message: L10n.t("bulk.keySpace", key)))
            }
            let lowered = key.lowercased()
            if let first = seen[lowered] {
                issues.append(Issue(line: line, message: L10n.t("bulk.duplicate", key, L10n.number(first))))
            } else {
                seen[lowered] = line
            }
        }
        return issues
    }

    /// Doğrular ve normalize eder: `anahtar: değer`, boş satırlar atılır.
    /// Sorun varsa metne dokunmadan hata fırlatır.
    public static func beautify(_ text: String) throws -> String {
        let issues = validate(text)
        guard issues.isEmpty else { throw ValidationError(issues: issues) }
        return encode(decode(text))
    }

    private static func parse(_ rawLine: String) -> (key: String, value: String, enabled: Bool)? {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        var enabled = true
        if line.hasPrefix(disabledPrefix) {
            enabled = false
            line = String(line.dropFirst(disabledPrefix.count))
        }
        guard let separator = line.firstIndex(of: ":") else { return nil }
        let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value, enabled)
    }
}
