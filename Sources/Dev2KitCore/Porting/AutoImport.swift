import Foundation

/// Otomatik içe aktarma (kullanıcı kararı, 2026-10-19): yapıştırılan metin
/// ya da dosyadan çıkarılan metin neyse onu tanır. Kullanıcı türü seçmez.
///
/// - Bütün metin JSON ise içeriğinden: dev2kit koleksiyonu, Postman
///   koleksiyonu, OpenAPI/Swagger, Kibana kaydı.
/// - Değilse (belge, sohbet, README) metnin İÇİNDEKİ her `curl` komutu ve
///   her JSON bloğu: koleksiyon, Kibana kaydı, OpenAPI. Kullanıcı önce
///   "belgelerden yalnızca cURL" dedi, sonra koleksiyon ve Kibana kaydını da
///   istedi (2026-10-19). Bir belge birden çok tür içerebilir: sonuç liste.
public enum AutoImport {
    public struct Findings: Sendable {
        public var curl: [CurlFinding] = []
        public var collections: [CollectionFinding] = []
        /// Bulunan Kibana kayıtları (belge nesneleri); kendi ekranında
        /// (alan eşleme, ortam denetimi) tek seferde aktarılır.
        public var kibanaDocuments: [String] = []
        /// İlk bulunan OpenAPI dokümanı (sunucu ve grup seçimi kendi ekranında).
        public var openAPI: String?
        /// Hiçbir şey bulunamadıysa kullanıcıya gösterilecek sebep.
        public var emptyReason: String?
        /// Değeri satır sonunda kesik bulunan alanlar (PDF dönüşümü uzun
        /// satırı kesmiş): içe aktarılan değer eksik olabilir, kullanıcı uyarılır.
        public var truncatedFields: [String] = []
        /// Kibana kaydı JSON okunamadığı için bozuk metinden (ör. OCR) alan alan
        /// kurtarıldı: değerler hata taşıyabilir, kullanıcı uyarılır.
        public var recoveredFromDamagedText = false

        public var isEmpty: Bool { curl.isEmpty && collections.isEmpty && kibanaDocuments.isEmpty && openAPI == nil }

        /// Kibana ekranına verilecek JSON: tek kayıt kendisi, birden çoksa dizi.
        public var kibanaJSON: String? {
            guard !kibanaDocuments.isEmpty else { return nil }
            return kibanaDocuments.count == 1 ? kibanaDocuments[0] : "[" + kibanaDocuments.joined(separator: ",\n") + "]"
        }
    }

    public struct CurlFinding: Identifiable, Sendable {
        public let id: Int
        public let command: String
        public let request: RequestModel
        public let warnings: [String]
    }

    public struct CollectionFinding: Identifiable, Sendable {
        public enum Kind: Sendable { case dev2kit, postman }
        public let id: Int
        public let kind: Kind
        public let name: String
        public let data: Data
    }

    /// En çok bu kadar JSON bloğu tanınır (her tür için).
    public static let maxJSONFindings = 50

    public static func scan(_ text: String) -> Findings {
        var findings = Findings()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            findings.emptyReason = "İçe aktarılacak metin yok."
            return findings
        }
        if let first = trimmed.first, first == "{" || first == "[",
           let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) {
            add(json, text: trimmed, to: &findings, allowArrays: true)
            if findings.isEmpty {
                findings.emptyReason = "JSON tanınmadı: koleksiyon, OpenAPI ya da Kibana kaydı değil."
            }
            return findings
        }
        findings.curl = curlFindings(in: text)
        for block in JSONBlockExtractor.blocks(in: CurlExtractor.normalized(text)) {
            let before = findings.collections.count + findings.kibanaDocuments.count + (findings.openAPI == nil ? 0 : 1)
            add(block.value, text: block.text, to: &findings, allowArrays: true)
            let after = findings.collections.count + findings.kibanaDocuments.count + (findings.openAPI == nil ? 0 : 1)
            if after > before {
                findings.truncatedFields += block.truncatedKeys.filter { !findings.truncatedFields.contains($0) }
            }
        }
        if findings.kibanaDocuments.isEmpty {
            for record in LooseKibanaRecovery.records(in: CurlExtractor.normalized(text)).prefix(maxJSONFindings) {
                findings.kibanaDocuments.append(record.json)
                findings.truncatedFields += record.truncatedKeys
                findings.recoveredFromDamagedText = true
            }
        }
        if findings.isEmpty {
            findings.emptyReason = "Tanınan bir içerik yok: cURL komutu, Postman ya da dev2kit koleksiyonu, Kibana kaydı, OpenAPI JSON'u bulunamadı."
        }
        return findings
    }

    // MARK: JSON

    private static func add(_ json: Any, text: String, to findings: inout Findings, allowArrays: Bool) {
        if let array = json as? [Any] {
            // Kayıt dizisi: her eleman ayrı değerlendirilir (Kibana kayıtları).
            for element in array where allowArrays {
                guard let object = element as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: object) else { continue }
                add(object, text: String(decoding: data, as: UTF8.self), to: &findings, allowArrays: false)
            }
            return
        }
        guard let object = json as? [String: Any] else { return }
        let data = Data(text.utf8)
        if object["format"] as? String == CollectionPorting.currentFormat,
           findings.collections.count < maxJSONFindings {
            let name = (object["collection"] as? [String: Any])?["name"] as? String ?? "dev2kit koleksiyonu"
            findings.collections.append(CollectionFinding(id: findings.collections.count, kind: .dev2kit, name: name, data: data))
        } else if let postman = isPostman(object) ? object : (object["collection"] as? [String: Any]).flatMap({ isPostman($0) ? $0 : nil }),
                  findings.collections.count < maxJSONFindings {
            let name = (postman["info"] as? [String: Any])?["name"] as? String ?? "Postman koleksiyonu"
            findings.collections.append(CollectionFinding(id: findings.collections.count, kind: .postman, name: name, data: data))
        } else if object["openapi"] is String || object["swagger"] is String {
            if findings.openAPI == nil { findings.openAPI = text }
        } else if isKibanaDocument(object) {
            if findings.kibanaDocuments.count < maxJSONFindings { findings.kibanaDocuments.append(text) }
        } else if let hits = (object["hits"] as? [String: Any])?["hits"] as? [Any] {
            // Arama yanıtı: içindeki kayıtlar.
            add(hits, text: text, to: &findings, allowArrays: true)
        }
    }

    private static func isPostman(_ object: [String: Any]) -> Bool {
        guard let schema = (object["info"] as? [String: Any])?["schema"] as? String else { return false }
        return schema.contains("getpostman.com")
    }

    private static func isKibanaDocument(_ object: [String: Any]) -> Bool {
        object["_source"] is [String: Any] || (object["_index"] is String && object["fields"] is [String: Any])
    }

    // MARK: cURL

    /// En çok bu kadar komut: dev bir belge yüzlerce istek açmasın.
    public static let maxCurlCommands = 200
    /// Bir komut en çok bu kadar satır sürer (gövdesi çok satırlı JSON olabilir).
    static let maxCommandLines = 400

    static func curlFindings(in text: String) -> [CurlFinding] {
        var findings: [CurlFinding] = []
        for command in CurlExtractor.commands(in: text).prefix(maxCurlCommands) {
            guard let result = try? CurlImporter.parse(command) else { continue }
            var request = result.request
            request.name = name(for: request)
            findings.append(CurlFinding(id: findings.count, command: command, request: request, warnings: result.warnings))
        }
        return findings
    }

    /// "GET /v1/items": dokümandaki istekler ayırt edilebilsin.
    static func name(for request: RequestModel) -> String {
        let path = URLComponents(string: request.url)?.path ?? ""
        return "\(request.method.rawValue) \(path.isEmpty ? request.url : path)"
    }
}

/// Serbest metindeki (belge, sohbet, README) `curl` komutlarını bulur.
///
/// - Komut, satırda "curl " ile başlayan yerden başlar (önünde `$ `, `> `
///   gibi istem ya da "Örnek:" gibi bir metin olabilir).
/// - Satır sonunda `\` (Unix), `^` (Windows) ya da `` ` `` (PowerShell)
///   varsa ya da açılmış tırnak kapanmamışsa sonraki satır komuta katılır.
/// - PDF/Word metnindeki kıvrık tırnaklar düz tırnağa çevrilir: yoksa
///   kabuk ayrıştırması tırnakları tanımıyor.
public enum CurlExtractor {
    public static func commands(in text: String) -> [String] {
        let lines = normalized(text).components(separatedBy: "\n")
        var commands: [String] = []
        var index = 0
        while index < lines.count {
            guard let start = curlStart(in: lines[index]) else { index += 1; continue }
            var parts = [String(lines[index][start...])]
            var quote: Character? = openQuote(after: nil, in: parts[0])
            var continues = endsWithContinuation(parts[0])
            var used = 1
            while (continues || quote != nil), index + used < lines.count, used < AutoImport.maxCommandLines {
                let next = lines[index + used]
                if continues, quote == nil {
                    parts[parts.count - 1] = dropContinuation(parts[parts.count - 1])
                }
                parts.append(next)
                quote = openQuote(after: quote, in: next)
                continues = quote == nil && endsWithContinuation(next)
                used += 1
            }
            if quote != nil {
                // Tırnak hiç kapanmadı (belgede yanlış yazılmış örnek): yalnızca
                // ilk satır alınır, arkasındaki komutlar yutulmasın.
                commands.append(dropContinuation(parts[0]))
                index += 1
                continue
            }
            if continues { parts[parts.count - 1] = dropContinuation(parts[parts.count - 1]) }
            // Tırnak içindeki satır sonu korunur (çok satırlı JSON gövdesi);
            // dışarıdaki devam satırları boşlukla birleşir.
            commands.append(join(parts))
            index += used
        }
        return commands
    }

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            // PDF'te "--header" bazen tek bir uzun tire olarak çıkar.
            .replacingOccurrences(of: "\u{2013}", with: "--")
            .replacingOccurrences(of: "\u{2014}", with: "--")
    }

    /// "curl" kelimesinin (bağımsız kelime olarak) başladığı yer.
    static func curlStart(in line: String) -> String.Index? {
        var search = line.startIndex
        while let range = line.range(of: "curl", options: .caseInsensitive, range: search..<line.endIndex) {
            let before = range.lowerBound == line.startIndex ? nil : line[line.index(before: range.lowerBound)]
            let after = range.upperBound == line.endIndex ? nil : line[range.upperBound]
            let boundaryBefore = before.map { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "/" && $0 != "." } ?? true
            if boundaryBefore, after == " " || after == "\t" {
                return range.lowerBound
            }
            search = range.upperBound
        }
        return nil
    }

    static func endsWithContinuation(_ line: String) -> Bool {
        guard let last = line.trimmingCharacters(in: .whitespaces).last else { return false }
        return last == "\\" || last == "^" || last == "`"
    }

    static func dropContinuation(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if endsWithContinuation(trimmed) { trimmed.removeLast() }
        return trimmed.trimmingCharacters(in: .whitespaces)
    }

    /// Satır sonunda açık kalan tırnak (`'` ya da `"`); kaçışlı `\"` sayılmaz.
    static func openQuote(after current: Character?, in line: String) -> Character? {
        var quote = current
        var escaped = false
        for character in line {
            if escaped { escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            }
        }
        return quote
    }

    private static func join(_ parts: [String]) -> String {
        var result = parts[0]
        var quote = openQuote(after: nil, in: parts[0])
        for part in parts.dropFirst() {
            // Tırnak dışındaki devam satırının girintisi atılır.
            let piece = quote != nil ? part : String(part.drop { $0 == " " || $0 == "\t" })
            result += (quote != nil ? "\n" : " ") + piece
            quote = openQuote(after: quote, in: part)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

/// Serbest metindeki JSON blokları (`{…}` ya da `[…]`): belgeye gömülü
/// koleksiyon, Kibana kaydı, OpenAPI dokümanı.
///
/// Parantez eşleme tırnak duyarlı (metin içindeki `}` sayılmaz). Eşleşen
/// blok gerçekten JSON olarak okunabiliyorsa alınır ve atlanır; okunamıyorsa
/// bir sonraki karakterden devam edilir. Düzyazıdaki kapanmamış `{` her
/// seferinde metnin sonuna kadar taranabileceği için toplam tarama bir
/// bütçeyle sınırlı (en kötü durumda ~yüz milisaniye).
/// PDF'ten çıkan JSON sayfa başlığıyla bölünmüşse okunamaz; en iyi çaba.
enum JSONBlockExtractor {
    struct Block {
        let text: String
        let value: Any
        /// Toleranslı okumada değeri satır sonunda kesik bulunan alanlar.
        var truncatedKeys: [String] = []
    }

    static let scanBudget = 50_000_000

    static func blocks(in text: String) -> [Block] {
        let bytes = Array(text.utf8)
        var blocks: [Block] = []
        var budget = scanBudget
        var index = 0
        while index < bytes.count, budget > 0 {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") else { index += 1; continue }
            let (end, scanned) = matchingEnd(bytes, from: index, budget: budget)
            budget -= scanned
            if let end, let block = parse(Array(bytes[index...end])) {
                blocks.append(block)
                index = end + 1
            } else if let repaired = tolerant(bytes, from: index, budget: max(budget, 0)) {
                budget -= repaired.scanned
                if let value = try? JSONSerialization.jsonObject(with: Data(repaired.bytes)),
                   value is [String: Any] || value is [Any] {
                    blocks.append(Block(text: String(decoding: repaired.bytes, as: UTF8.self), value: value, truncatedKeys: repaired.truncatedKeys))
                    index = repaired.end + 1
                } else {
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return blocks
    }

    /// Blok JSON olarak okunuyorsa; okunmuyorsa PDF onarımıyla bir kez daha.
    private static func parse(_ bytes: [UInt8]) -> Block? {
        for candidate in [bytes, withoutBreaksInsideStrings(bytes)] {
            if let value = try? JSONSerialization.jsonObject(with: Data(candidate)),
               value is [String: Any] || value is [Any] {
                return Block(text: String(decoding: candidate, as: UTF8.self), value: value)
            }
        }
        return nil
    }

    /// PDF metin çıkarımı bazı karakterlerin (ör. `_`) çevresine satır sonu
    /// koyuyor: `"_index"` metinde `"⏎_⏎index"` olarak geliyor (ölçüldü,
    /// PDFKit). JSON metninde ham satır sonu OLAMAZ; tırnak içindekiler silinir.
    static func withoutBreaksInsideStrings(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var inString = false
        var escaped = false
        for byte in bytes {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                } else if byte == 0x0A || byte == 0x0D {
                    continue
                }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            }
            output.append(byte)
        }
        return output
    }

    // MARK: Toleranslı okuma (kesik/sarılmış satırlı PDF)

    struct Repaired {
        let bytes: [UInt8]
        let end: Int
        let truncatedKeys: [String]
        let scanned: Int
    }

    /// Metinden PDF'e dönüştürücüler sayfaya sığmayan satırı ya KESER (gerisi
    /// kaybolur, kapanış tırnağı yok) ya da SARAR (devamı sonraki satırda).
    /// Kullanıcının dosyasında ölçüldü (2026-10-19): `response_body` satır
    /// sonunda kesik, sonraki satır `"headers": {` ile başlıyordu; JSON geçersiz.
    ///
    /// Tırnak içindeyken satır biterse sonraki satıra bakılır:
    /// - yeni anahtar (`"ad":`) ya da `}`/`]` ile başlıyorsa değer KESİLMİŞ:
    ///   tırnak (anahtardan önce virgülle) kapatılır, alan adı bildirilir;
    /// - değilse değer SARILMIŞ: satır sonu silinir.
    /// Tırnak dışında değer bitmiş ve sonraki satır yeni anahtarsa eksik
    /// virgül eklenir. Geçerli JSON bu kurallardan etkilenmez.
    static func tolerant(_ bytes: [UInt8], from start: Int, budget: Int) -> Repaired? {
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        var output: [UInt8] = []
        var depth = 0
        var inString = false
        var escaped = false
        var current: [UInt8] = []
        var lastString = ""
        var currentKey: String?
        var truncated: [String] = []
        var lastSignificant: UInt8 = 0
        var index = start
        let limit = min(bytes.count, start + budget)
        while index < limit {
            let byte = bytes[index]
            if inString {
                if byte == 0x0A || byte == 0x0D {
                    let next = nextLineStart(bytes, after: index)
                    let closesHere = !escaped && (startsWithKey(bytes, at: next)
                        || (next < bytes.count && (bytes[next] == UInt8(ascii: "}") || bytes[next] == UInt8(ascii: "]"))))
                    if closesHere {
                        output.append(quote)
                        inString = false
                        lastString = String(decoding: current, as: UTF8.self)
                        truncated.append(currentKey ?? "?")
                        lastSignificant = quote
                        if startsWithKey(bytes, at: next) {
                            output.append(UInt8(ascii: ","))
                            lastSignificant = UInt8(ascii: ",")
                        }
                        output.append(0x0A)
                    }
                    // Sarılmış satır: satır sonu atılır (kaçış durumu korunur).
                    index += 1
                    continue
                }
                output.append(byte)
                if escaped {
                    escaped = false
                } else if byte == backslash {
                    escaped = true
                } else if byte == quote {
                    inString = false
                    lastString = String(decoding: current, as: UTF8.self)
                    lastSignificant = quote
                    index += 1
                    continue
                }
                current.append(byte)
                index += 1
                continue
            }
            switch byte {
            case quote:
                inString = true
                current = []
                output.append(byte)
            case UInt8(ascii: ":"):
                currentKey = lastString
                output.append(byte)
                lastSignificant = byte
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                output.append(byte)
                lastSignificant = byte
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                output.append(byte)
                lastSignificant = byte
                if depth == 0 {
                    return Repaired(bytes: output, end: index, truncatedKeys: truncated, scanned: index - start + 1)
                }
            case 0x0A, 0x0D:
                if isValueEnd(lastSignificant), startsWithKey(bytes, at: nextLineStart(bytes, after: index)) {
                    output.append(UInt8(ascii: ","))
                    lastSignificant = UInt8(ascii: ",")
                }
                output.append(byte)
            case 0x20, 0x09:
                output.append(byte)
            default:
                output.append(byte)
                lastSignificant = byte
            }
            index += 1
        }
        return nil
    }

    /// Sonraki satırın ilk boşluk olmayan baytı.
    private static func nextLineStart(_ bytes: [UInt8], after index: Int) -> Int {
        var next = index + 1
        while next < bytes.count, bytes[next] == 0x0A || bytes[next] == 0x0D || bytes[next] == 0x20 || bytes[next] == 0x09 {
            next += 1
        }
        return next
    }

    /// Satır `"ad":` ile mi başlıyor (aynı satırda).
    private static func startsWithKey(_ bytes: [UInt8], at start: Int) -> Bool {
        guard start < bytes.count, bytes[start] == UInt8(ascii: "\"") else { return false }
        var index = start + 1
        var escaped = false
        while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
            let byte = bytes[index]
            if escaped {
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\"") {
                var after = index + 1
                while after < bytes.count, bytes[after] == 0x20 || bytes[after] == 0x09 { after += 1 }
                return after < bytes.count && bytes[after] == UInt8(ascii: ":")
            }
            index += 1
        }
        return false
    }

    /// Bir JSON değerinin son karakteri olabilir mi (tırnak, kapanış, sayı, true/false/null).
    private static func isValueEnd(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]")
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "l")
    }

    /// Açılış parantezine karşılık gelen kapanış; bütçe ya da metin biterse `nil`.
    static func matchingEnd(_ bytes: [UInt8], from start: Int, budget: Int) -> (Int?, Int) {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        let limit = min(bytes.count, start + budget)
        while index < limit {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                depth += 1
            } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 { return (index, index - start + 1) }
            }
            index += 1
        }
        return (nil, index - start)
    }
}

/// Bozuk metinden Kibana kaydı kurtarma: JSON hiç okunamadığında (ölçüldü,
/// 2026-10-19: resimden OCR ile çıkarılıp PDF'e dönüştürülmüş bir logda
/// kapanış satırları tekrar etmiş ya da kaybolmuştu) içe aktarma için
/// gereken alanlar tek tek çıkarılır ve temiz bir kayıt kurulur.
///
/// Değerler OCR hatası taşıyabilir (0/O, l/1): arayüz bunu açıkça söyler.
enum LooseKibanaRecovery {
    struct Recovered {
        let json: String
        let truncatedKeys: [String]
    }

    /// Metindeki her `"_index"` bir kayıt başlangıcı sayılır.
    static func records(in text: String) -> [Recovered] {
        let starts = ranges(of: #""_index"\s*:\s*""#, in: text).map(\.lowerBound)
        guard !starts.isEmpty else { return [] }
        var records: [Recovered] = []
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : text.endIndex
            if let record = record(in: String(text[start..<end])) { records.append(record) }
        }
        return records
    }

    private static func record(in segment: String) -> Recovered? {
        guard let index = stringValue("_index", in: segment),
              let path = stringValue("request_path", in: segment) else { return nil }
        var truncated: [String] = []
        var source: [String: Any] = ["request_path": path]
        for key in ["http_method", "service_name", "status_code", "start_time"] {
            if let value = stringValue(key, in: segment) { source[key] = value }
        }
        if let body = stringValue("request_body", in: segment, truncated: &truncated) { source["request_body"] = body }
        let headers = headerBlock(in: segment, truncated: &truncated)
        if !headers.isEmpty { source["headers"] = headers }
        let document: [String: Any] = ["_index": index, "_source": source]
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return Recovered(json: String(decoding: data, as: UTF8.self), truncatedKeys: truncated)
    }

    /// `"anahtar": "değer"` (aynı satırda; dizi biçimli `fields` kopyası eşleşmez).
    private static func stringValue(_ key: String, in text: String) -> String? {
        var ignored: [String] = []
        return stringValue(key, in: text, truncated: &ignored)
    }

    private static func stringValue(_ key: String, in text: String, truncated: inout [String]) -> String? {
        let pattern = #"""# + NSRegularExpression.escapedPattern(for: key) + #""\s*:\s*"((?:[^"\\\n]|\\.)*)("?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        if match.range(at: 2).length == 0 { truncated.append(key) }
        return unescape(String(text[range]))
    }

    /// `"headers": {` sonrasındaki `"ad": "değer"` satırları, bloğu kapatan
    /// `}` satırına kadar. Anahtarla başlamayan satır önceki değerin devamıdır
    /// (sarılmış uzun token); kapanış tırnağı olmayan değer kesik sayılır.
    private static func headerBlock(in text: String, truncated: inout [String]) -> [String: String] {
        guard let open = ranges(of: #""headers"\s*:\s*\{"#, in: text).first else { return [:] }
        var headers: [String: String] = [:]
        var lastKey: String?
        var lastClosed = true
        let linePattern = try! NSRegularExpression(pattern: #"^\s*"([^"]+)"\s*:\s*"((?:[^"\\]|\\.)*)("?)\s*,?\s*$"#)
        for line in text[open.upperBound...].components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("}") { break }
            if let match = linePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let keyRange = Range(match.range(at: 1), in: line), let valueRange = Range(match.range(at: 2), in: line) {
                if let previous = lastKey, !lastClosed { truncated.append("headers.\(previous)") }
                let key = String(line[keyRange])
                headers[key] = unescape(String(line[valueRange]))
                lastKey = key
                lastClosed = match.range(at: 3).length > 0
            } else if let key = lastKey, !lastClosed, !trimmed.isEmpty,
                      !trimmed.hasPrefix("\"") || headers[key, default: ""].isEmpty {
                // Sarılmış değerin devamı ya da sonraki satırda başlayan değer
                // (`"ad":` ⏎ `"değer…`); kapanış tırnağı bu satırda olabilir.
                var piece = trimmed
                if headers[key, default: ""].isEmpty, piece.hasPrefix("\"") { piece.removeFirst() }
                if piece.hasSuffix(",") { piece.removeLast() }
                if piece.hasSuffix("\"") { piece.removeLast(); lastClosed = true }
                headers[key, default: ""] += piece
            } else if trimmed.hasPrefix("\""), trimmed.hasSuffix(":") || trimmed.hasSuffix("\":") {
                // "ad": (değer sonraki satırda)
                lastKey = String(trimmed.dropFirst().prefix { $0 != "\"" })
                headers[lastKey!] = ""
                lastClosed = false
            }
        }
        for (key, value) in headers where value.isEmpty { headers[key] = nil }
        if let key = lastKey, !lastClosed, headers[key] != nil { truncated.append("headers.\(key)") }
        return headers
    }

    private static func unescape(_ value: String) -> String {
        guard value.contains("\\"),
              let data = "\"\(value)\"".data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else { return value }
        return decoded
    }

    private static func ranges(of pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }
}
