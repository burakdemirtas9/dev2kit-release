import Compression
import Foundation

/// Yalnızca okuyan, küçük ZIP okuyucusu: Word (.docx) ve Excel (.xlsx)
/// dosyaları ZIP arşividir. Yeni bağımlılık eklememek için burada; açma
/// Apple `Compression` (ham DEFLATE).
///
/// Güvenlik (zip bombası): açmadan ÖNCE merkez dizindeki açık boyutlar
/// toplanır, sınırı aşan arşiv reddedilir. Açılan her girdi ilan edilen
/// boyuttan büyük yazılamaz (çıktı arabelleği o boyutta), farklı çıkarsa hata.
/// ZIP64, şifreli ve DEFLATE dışı sıkıştırılmış girdiler desteklenmez.
public struct ZipReader: Sendable {
    public struct Entry: Sendable {
        public let name: String
        let method: UInt16
        let compressedSize: Int
        public let uncompressedSize: Int
        let localHeaderOffset: Int
        let encrypted: Bool
    }

    public struct ZipError: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Açık toplam boyut sınırı (zip bombası).
    public static let maxTotalUncompressed = 200 * 1_024 * 1_024
    public static let maxEntries = 20_000

    public let entries: [Entry]
    private let data: Data

    public init(_ data: Data) throws {
        self.data = data
        guard let end = Self.endOfCentralDirectory(in: data) else {
            throw ZipError(message: "Arşiv okunamadı (ZIP dizini yok).")
        }
        let count = Int(data.u16(at: end + 10))
        let directoryOffset = Int(data.u32(at: end + 16))
        guard count <= Self.maxEntries else { throw ZipError(message: "Arşivde çok fazla dosya var (\(count)).") }
        guard data.u32(at: end + 16) != 0xFFFF_FFFF else { throw ZipError(message: "ZIP64 arşivi desteklenmiyor.") }

        var entries: [Entry] = []
        var offset = directoryOffset
        var total = 0
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.u32(at: offset) == 0x0201_4B50 else {
                throw ZipError(message: "Arşiv bozuk (dizin kaydı).")
            }
            let flags = data.u16(at: offset + 8)
            let method = data.u16(at: offset + 10)
            let compressed = data.u32(at: offset + 20)
            let uncompressed = data.u32(at: offset + 24)
            let nameLength = Int(data.u16(at: offset + 28))
            let extraLength = Int(data.u16(at: offset + 30))
            let commentLength = Int(data.u16(at: offset + 32))
            let localOffset = data.u32(at: offset + 42)
            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else {
                throw ZipError(message: "ZIP64 arşivi desteklenmiyor.")
            }
            guard offset + 46 + nameLength <= data.count else { throw ZipError(message: "Arşiv bozuk (dosya adı).") }
            let name = String(decoding: data[(data.startIndex + offset + 46)..<(data.startIndex + offset + 46 + nameLength)], as: UTF8.self)
            total += Int(uncompressed)
            guard total <= Self.maxTotalUncompressed else {
                throw ZipError(message: "Arşiv açılınca \(Self.maxTotalUncompressed / 1_048_576) MB'ı aşıyor; açılmadı (zip bombası olabilir).")
            }
            entries.append(Entry(
                name: name, method: method, compressedSize: Int(compressed), uncompressedSize: Int(uncompressed),
                localHeaderOffset: Int(localOffset), encrypted: flags & 1 != 0
            ))
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    public func contains(_ name: String) -> Bool { entries.contains { $0.name == name } }

    /// Girdinin açılmış içeriği.
    public func contents(of name: String) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name }) else {
            throw ZipError(message: "Arşivde \(name) yok.")
        }
        guard !entry.encrypted else { throw ZipError(message: "Şifreli dosya açılamaz.") }
        let local = entry.localHeaderOffset
        guard local + 30 <= data.count, data.u32(at: local) == 0x0403_4B50 else {
            throw ZipError(message: "Arşiv bozuk (yerel başlık).")
        }
        let start = local + 30 + Int(data.u16(at: local + 26)) + Int(data.u16(at: local + 28))
        guard start + entry.compressedSize <= data.count else { throw ZipError(message: "Arşiv bozuk (kısa veri).") }
        let compressed = data[(data.startIndex + start)..<(data.startIndex + start + entry.compressedSize)]
        switch entry.method {
        case 0:
            return Data(compressed)
        case 8:
            guard entry.uncompressedSize > 0 else { return Data() }
            var output = Data(count: entry.uncompressedSize)
            let written = output.withUnsafeMutableBytes { destination in
                compressed.withUnsafeBytes { source in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!, entry.uncompressedSize,
                        source.bindMemory(to: UInt8.self).baseAddress!, entry.compressedSize,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            guard written == entry.uncompressedSize else { throw ZipError(message: "Arşiv bozuk (\(name) açılamadı).") }
            return output
        default:
            throw ZipError(message: "Desteklenmeyen sıkıştırma (\(entry.method)).")
        }
    }

    /// Dosyanın sonundaki "merkez dizin sonu" kaydı (yorum en çok 64 KB).
    private static func endOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 22 - 65_535)
        var offset = data.count - 22
        while offset >= lowest {
            if data.u32(at: offset) == 0x0605_4B50 { return offset }
            offset -= 1
        }
        return nil
    }
}

private extension Data {
    func u16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func u32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * UInt32($1)) }
    }
}
