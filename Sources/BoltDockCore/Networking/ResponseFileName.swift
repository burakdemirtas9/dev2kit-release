import Foundation
import UniformTypeIdentifiers

/// "Dosyaya Kaydet…" penceresinde önerilecek dosya adı.
///
/// Ad sunucunun gönderdiği veriden (Content-Disposition, URL) türetilir, yani
/// güvenilmez girdidir: yol ayırıcıları, kontrol/yön karakterleri ve baştaki
/// noktalar temizlenir. Ad yalnızca bir öneridir; nereye ve hangi adla
/// kaydedileceğine kaydetme penceresinde kullanıcı karar verir.
public enum ResponseFileName {
    static let fallbackBaseName = "response"
    static let maxLength = 120

    /// Öncelik: Content-Disposition'daki ad → URL'nin son parçası (uzantılıysa)
    /// → son parça ya da "response" + Content-Type'tan türetilen uzantı.
    public static func suggested(for response: ResponseData) -> String {
        if let disposition = header("content-disposition", in: response),
           let name = dispositionFileName(disposition).map(sanitize), !name.isEmpty {
            return limitLength(name)
        }
        // Kök yolda lastPathComponent "/" döner; ad değil, ayırıcıdır.
        let lastComponent = response.finalURL
            .map(\.lastPathComponent)
            .flatMap { $0 == "/" ? nil : sanitize($0) } ?? ""
        if hasMeaningfulExtension(lastComponent) {
            return limitLength(lastComponent)
        }
        let base = lastComponent.isEmpty ? fallbackBaseName : lastComponent
        let ext = fileExtension(contentType: header("content-type", in: response), body: response.body)
        return limitLength("\(base).\(ext)")
    }

    // MARK: - Content-Disposition

    /// `filename*` (RFC 5987, UTF-8) varsa o, yoksa `filename` döner.
    /// Tırnak içinde `;` geçen adlar parçalanabilir; sonuç yine temizlendiği
    /// için bu yalnızca önerinin kalitesini etkiler, güvenliği değil.
    static func dispositionFileName(_ value: String) -> String? {
        var plain: String?
        for part in value.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            var raw = pair[1].trimmingCharacters(in: .whitespaces)
            if key == "filename*" {
                // Biçim: charset'dil'yüzde-kodlu-ad → UTF-8''rapor%20%C3%B6zet.pdf
                let pieces = raw.components(separatedBy: "'")
                if pieces.count == 3, pieces[0].lowercased() == "utf-8",
                   let decoded = pieces[2].removingPercentEncoding {
                    return decoded
                }
            } else if key == "filename" {
                if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
                    raw = String(raw.dropFirst().dropLast())
                }
                plain = raw
            }
        }
        return plain
    }

    // MARK: - Temizlik

    /// Yol ayırıcıları `_` olur; kontrol ve biçim karakterleri (U+202E gibi
    /// "exe.pdf" sahteciliği yapan yön işaretleri dahil) atılır; baştaki
    /// noktalar düşer ki dosya gizli olmasın ve "." / ".." boşalsın.
    static func sanitize(_ name: String) -> String {
        let separators = CharacterSet(charactersIn: "/\\:")
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            scalars.append(separators.contains(scalar) ? "_" : scalar)
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
    }

    /// Uzun adları keserken uzantıyı korur.
    static func limitLength(_ name: String) -> String {
        guard name.count > maxLength else { return name }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, ext.count < 16 else { return String(name.prefix(maxLength)) }
        let base = (name as NSString).deletingPathExtension
        return "\(base.prefix(maxLength - ext.count - 1)).\(ext)"
    }

    /// "v1.2" gibi sürüm parçaları uzantı sayılmasın diye harf içermesi aranır.
    private static func hasMeaningfulExtension(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        return !ext.isEmpty && ext.count <= 8 && ext.contains { $0.isLetter }
    }

    // MARK: - Uzantı

    static func fileExtension(contentType: String?, body: Data) -> String {
        let mime = contentType?
            .split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        // application/problem+json gibi yapısal son ekler sistemde tanımlı değil.
        if mime.hasSuffix("+json") { return "json" }
        if mime.hasSuffix("+xml") { return "xml" }
        if !mime.isEmpty, let ext = UTType(mimeType: mime)?.preferredFilenameExtension {
            return ext
        }
        return String(data: body, encoding: .utf8) != nil ? "txt" : "bin"
    }

    private static func header(_ name: String, in response: ResponseData) -> String? {
        response.headers.first { $0.name.lowercased() == name }?.value
    }
}
