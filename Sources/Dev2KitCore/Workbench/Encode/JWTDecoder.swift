import Foundation

/// JWT çözücü (step 2a). Başlık ve yük okunur, zaman alanları okunur tarihe
/// ve kalan süreye çevrilir. İmza DOĞRULANMAZ ve çıktı bunu açıkça söyler
/// (kullanıcı kararı, 2026-10-19: doğrulama sonra; anahtar girişi ayrı
/// güvenlik soruları açıyor).
///
/// "Bearer " öneki ve çevresindeki boşluk/tırnak atılır: Authorization
/// başlığından olduğu gibi yapıştırılabilsin. JWE (5 parça) şifrelidir,
/// çözülemez.
public enum JWTDecoder {
    static let timeClaims = ["exp", "iat", "nbf", "auth_time"]

    public static func decode(_ input: String, indent: String = "  ", now: Date = Date(), timeZone: TimeZone = .current) throws -> String {
        let parts = try segments(of: input)
        let header = try json(parts[0], name: "header")
        let payload = try json(parts[1], name: "payload")

        var lines = ["// Header", try JSONTool.format(header.text, options: WorkbenchOptions(indentation: indentation(indent))),
                     "", "// Payload", try JSONTool.format(payload.text, options: WorkbenchOptions(indentation: indentation(indent)))]
        let times = timeClaims.compactMap { claim -> String? in
            guard let seconds = number(payload.object[claim]) else { return nil }
            // Aşırı değer (1e300, -1e20) çökertmesin: açıklamayla gösterilir.
            guard TimeText.isRepresentable(seconds) else {
                return "// \(claim.padding(toLength: 9, withPad: " ", startingAt: 0)) out of range: \(seconds) — not a valid time"
            }
            let date = Date(timeIntervalSince1970: seconds)
            var line = "// \(claim.padding(toLength: 9, withPad: " ", startingAt: 0)) \(TimeText.local(date, timeZone)) · \(TimeText.utc(date)) · \(TimeText.relative(date, now: now))"
            if claim == "exp", date <= now { line += " — EXPIRED" }
            if claim == "nbf", date > now { line += " — NOT YET VALID" }
            return line
        }
        if !times.isEmpty {
            lines += ["", "// Times (\(timeZone.identifier) · UTC)"] + times
        }
        let algorithm = header.object["alg"] as? String ?? "?"
        lines += ["", "// Signature NOT verified (decode only). Algorithm: \(algorithm)"]
        if algorithm.lowercased() == "none" { lines.append("// WARNING: alg \"none\" — unsigned token") }
        return lines.joined(separator: "\n")
    }

    /// Yapısal doğrulama: araç ekranının alt çubuğu için.
    public static func validate(_ input: String) -> WorkbenchValidation {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        do {
            let parts = try segments(of: input)
            _ = try json(parts[0], name: "header")
            _ = try json(parts[1], name: "payload")
            return .valid
        } catch let issue as WorkbenchIssue {
            return .invalid(issue)
        } catch {
            return .invalid(WorkbenchIssue(message: error.localizedDescription))
        }
    }

    static func segments(of input: String) throws -> [String] {
        var token = input.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 5 { throw WorkbenchIssue(message: L10n.t("jwt.jwe")) }
        guard parts.count == 3 else {
            throw WorkbenchIssue(message: L10n.t("jwt.parts", L10n.number(parts.count)))
        }
        return parts
    }

    private static func json(_ segment: String, name: String) throws -> (text: String, object: [String: Any]) {
        guard let data = Base64Codec.decode(segment) else {
            throw WorkbenchIssue(message: L10n.t("jwt.base64", name))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkbenchIssue(message: L10n.t("jwt.notObject", name))
        }
        return (String(decoding: data, as: UTF8.self), object)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func indentation(_ unit: String) -> Indentation {
        Indentation.allCases.first { $0.unit == unit } ?? .default
    }
}
