import Foundation

/// Otomatik içe aktarmaya verilen dosyanın doğrulanması ve metninin
/// çıkarılması (kullanıcı kararı, 2026-10-19: Word, Excel, PDF ve metin).
///
/// Tür UZANTIYA göre değil, içeriğin ilk baytlarına göre belirlenir:
/// `rapor.pdf` adlı bir program PDF sayılmaz. Belgelerden yalnızca METİN
/// okunur; makro, gömülü nesne, bağlantı çalıştırılmaz.
public enum ImportFile {
    public enum Kind: Equatable, Sendable {
        case pdf
        case word
        case excel
        /// UTF-8 metin: JSON, cURL, Markdown, düz metin.
        case text
    }

    public struct Rejection: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    public static let maxBytes = ImportReviewer.maxImportBytes
    /// "20 MB": sınır ikili (20 MiB); diğer içe aktarma ekranlarıyla aynı yazım.
    public static let maxSizeText = "\(maxBytes / 1_048_576) MB"

    public static func kind(of data: Data) -> Result<Kind, Rejection> {
        guard data.count <= maxBytes else {
            return .failure(Rejection(message: "Dosya çok büyük (\(TextStats.size(data.count))); en fazla \(maxSizeText)."))
        }
        guard !data.isEmpty else { return .failure(Rejection(message: "Dosya boş.")) }
        let head = [UInt8](data.prefix(8))
        func starts(_ bytes: [UInt8]) -> Bool { head.starts(with: bytes) }

        if starts([0x25, 0x50, 0x44, 0x46, 0x2D]) { return .success(.pdf) } // %PDF-
        if starts([0x50, 0x4B, 0x03, 0x04]) {
            guard let zip = try? ZipReader(data) else {
                return .failure(Rejection(message: "Arşiv okunamadı ya da açılınca çok büyük (zip bombası olabilir)."))
            }
            if zip.contains("word/document.xml") { return .success(.word) }
            if zip.contains("xl/workbook.xml") { return .success(.excel) }
            return .failure(Rejection(message: "ZIP arşivi desteklenmiyor; yalnızca Word (.docx) ve Excel (.xlsx)."))
        }
        if starts([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            return .failure(Rejection(message: "Eski Office biçimi (.doc/.xls) desteklenmiyor; dosyayı .docx ya da .xlsx olarak kaydedip tekrar dene."))
        }
        if starts([0xCF, 0xFA, 0xED, 0xFE]) || starts([0xCE, 0xFA, 0xED, 0xFE]) || starts([0xCA, 0xFE, 0xBA, 0xBE]) || starts([0x4D, 0x5A]) {
            return .failure(Rejection(message: "Çalıştırılabilir dosya; içe aktarılmaz."))
        }
        if starts([0x89, 0x50, 0x4E, 0x47]) || starts([0xFF, 0xD8, 0xFF]) || starts([0x47, 0x49, 0x46, 0x38]) {
            return .failure(Rejection(message: "Resim dosyası; içinden istek çıkarılamaz."))
        }
        // Metin: geçerli UTF-8 ve NUL bayt yok (ikili dosya değil).
        if !data.contains(0), String(data: data, encoding: .utf8) != nil {
            return .success(.text)
        }
        return .failure(Rejection(message: "Tanınmayan dosya türü; Word, Excel, PDF ya da metin dosyası ver."))
    }

    /// Word ve Excel'in metni (PDF arayüzde PDFKit ile çıkarılır).
    public static func text(of data: Data, kind: Kind) throws -> String {
        switch kind {
        case .text:
            return String(decoding: data, as: UTF8.self)
        case .word:
            let xml = try ZipReader(data).contents(of: "word/document.xml")
            return OfficeText.word(xml)
        case .excel:
            let zip = try ZipReader(data)
            guard zip.contains("xl/sharedStrings.xml") else { return "" }
            return OfficeText.excelSharedStrings(try zip.contents(of: "xl/sharedStrings.xml"))
        case .pdf:
            throw Rejection(message: "PDF metni arayüz katmanında çıkarılır.")
        }
    }
}

/// Office XML'inden düz metin. Dış varlıklar ÇÖZÜLMEZ (XXE): XMLParser'ın
/// varsayılanı; açıkça da kapatılır.
enum OfficeText {
    /// Word: her paragraf (`w:p`) bir satır; `w:t` metin, `w:tab` sekme,
    /// `w:br` satır sonu.
    static func word(_ xml: Data) -> String {
        let collector = Collector(textElement: "w:t", lineElement: "w:p", tabElement: "w:tab", breakElement: "w:br")
        return collector.run(xml)
    }

    /// Excel: her paylaşılan metin (`si`, bir hücrenin metni) bir satır.
    /// Komutlar metin hücrelerinde durur; sayılar ve formüller gerekmez.
    static func excelSharedStrings(_ xml: Data) -> String {
        let collector = Collector(textElement: "t", lineElement: "si", tabElement: nil, breakElement: nil)
        return collector.run(xml)
    }

    private final class Collector: NSObject, XMLParserDelegate {
        let textElement: String
        let lineElement: String
        let tabElement: String?
        let breakElement: String?
        private var output = ""
        private var inText = false

        init(textElement: String, lineElement: String, tabElement: String?, breakElement: String?) {
            self.textElement = textElement
            self.lineElement = lineElement
            self.tabElement = tabElement
            self.breakElement = breakElement
        }

        func run(_ xml: Data) -> String {
            let parser = XMLParser(data: xml)
            parser.shouldResolveExternalEntities = false
            parser.delegate = self
            parser.parse()
            return output
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if elementName == textElement { inText = true }
            if elementName == tabElement { output += "\t" }
            if elementName == breakElement { output += "\n" }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == textElement { inText = false }
            if elementName == lineElement { output += "\n" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { output += string }
        }
    }
}
