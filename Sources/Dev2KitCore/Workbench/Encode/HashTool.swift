import CryptoKit
import Foundation

/// Hash ve HMAC (step 2a), CryptoKit ile. Metnin UTF-8 baytları AYNEN
/// özetlenir (sondaki satır sonu dahil): çoğu "imza tutmuyor" sorununun
/// sebebi budur, istatistik satırı bayt sayısını gösterir.
public enum HashTool {
    public enum Algorithm: String, CaseIterable, Sendable {
        case sha256 = "SHA-256", sha512 = "SHA-512", sha1 = "SHA-1", md5 = "MD5"
        case hmacSHA256 = "HMAC-SHA256", hmacSHA512 = "HMAC-SHA512"

        public var isHMAC: Bool { self == .hmacSHA256 || self == .hmacSHA512 }
        /// Güvenlik için kullanılmamalı (çakışma bulunmuş); arayüz etiketler.
        public var isInsecure: Bool { self == .sha1 || self == .md5 }
    }

    public enum Output: String, CaseIterable, Hashable, Sendable {
        case hex = "Hex", base64 = "Base64"
    }

    public static func digest(_ text: String, algorithm: Algorithm, key: String = "", output: Output) throws -> String {
        let data = Data(text.utf8)
        let bytes: Data
        switch algorithm {
        case .sha256: bytes = Data(SHA256.hash(data: data))
        case .sha512: bytes = Data(SHA512.hash(data: data))
        case .sha1: bytes = Data(Insecure.SHA1.hash(data: data))
        case .md5: bytes = Data(Insecure.MD5.hash(data: data))
        case .hmacSHA256, .hmacSHA512:
            guard !key.isEmpty else { throw WorkbenchIssue(message: "HMAC için anahtar (key) gerekli") }
            let symmetric = SymmetricKey(data: Data(key.utf8))
            bytes = algorithm == .hmacSHA256
                ? Data(HMAC<SHA256>.authenticationCode(for: data, using: symmetric))
                : Data(HMAC<SHA512>.authenticationCode(for: data, using: symmetric))
        }
        return output == .hex ? HexCodec.encode(bytes) : bytes.base64EncodedString()
    }
}
