import Foundation

/// UUID (step 2a): v4 (rastgele) ve v7 (zaman sıralı, RFC 9562) üretme;
/// verilen UUID'lerin sürümünü ve v7'nin içindeki zamanı okuma.
public enum UUIDTool {
    public static let maxCount = 1_000

    public static func generate(version: Int, count: Int, now: Date = Date()) -> String {
        (0..<min(max(count, 1), maxCount)).map { _ in
            (version == 7 ? v7(now: now) : UUID()).uuidString.lowercased()
        }.joined(separator: "\n")
    }

    /// RFC 9562 §5.7: 48 bit Unix milisaniye + sürüm 7 + varyant + rastgele.
    static func v7(now: Date) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var generator = SystemRandomNumberGenerator()
        for index in 6..<16 { bytes[index] = UInt8.random(in: 0...255, using: &generator) }
        let milliseconds = UInt64(max(0, now.timeIntervalSince1970 * 1_000))
        for index in 0..<6 { bytes[index] = UInt8((milliseconds >> (8 * UInt64(5 - index))) & 0xFF) }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public static func inspect(_ input: String, timeZone: TimeZone = .current) throws -> String {
        let lines = input.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        return lines.prefix(maxCount).map { line in
            guard let uuid = UUID(uuidString: line.trimmingCharacters(in: CharacterSet(charactersIn: "{}\"'"))) else {
                return "\(line)  — not a valid UUID"
            }
            let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
            let version = Int(bytes[6] >> 4)
            var description = "\(uuid.uuidString.lowercased())  v\(version)"
            switch version {
            case 4: description += " (random)"
            case 7:
                let milliseconds = bytes[0..<6].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
                description += " (time-ordered) · \(TimeText.local(date, timeZone)) · \(TimeText.utc(date))"
            case 1: description += " (time + MAC address)"
            case 3: description += " (MD5 name-based)"
            case 5: description += " (SHA-1 name-based)"
            default: break
            }
            if uuid.uuidString == "00000000-0000-0000-0000-000000000000" { description = "\(line)  nil UUID" }
            return description
        }.joined(separator: "\n")
    }
}
