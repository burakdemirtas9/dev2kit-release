import Foundation

/// Alan içindeki `{{...}}` şablonlarının gösterimi: parçalara ayırma ve
/// tıklanınca baloncukta ne gösterileceği (kullanıcı isteği, 2026-10-19).
///
/// Çözüm sırası gönderimle aynı (`TokenFactory.environmentForSend`,
/// `VariableResolver`): `secret:` → Keychain, sonra Token Factory değişkeni
/// (environment'taki aynı adı ezer), sonra etkin environment değişkeni.
///
/// Secret DEĞERİ önizlemeye girmez (yalnızca adı). Token Factory değeri
/// kullanıcı isteğiyle (2026-10-20) baloncukta gösterilir; onu arayüz
/// bellekteki önbellekten okur, bu tip yalnızca kaynağı söyler.
public enum TemplateVariables {
    public enum Segment: Equatable, Sendable {
        case text(String)
        /// `raw` alanda yazıldığı gibi (`{{ ad }}`), `name` kırpılmış ad.
        case variable(raw: String, name: String)
    }

    public enum Preview: Equatable, Sendable {
        case environment(environmentName: String, value: String)
        case token(requestName: String)
        case secret(name: String, exists: Bool)
        case undefined(environmentName: String?)

        public var isDefined: Bool {
            switch self {
            case .environment, .token: return true
            case .secret(_, let exists): return exists
            case .undefined: return false
            }
        }
    }


    public static func containsVariable(_ text: String) -> Bool {
        text.contains("{{") && text.contains("}}")
    }

    public static func segments(in text: String) -> [Segment] {
        guard containsVariable(text) else { return text.isEmpty ? [] : [.text(text)] }
        var result: [Segment] = []
        var last = text.startIndex
        for match in TemplateScanner.matches(in: text) {
            if last < match.range.lowerBound { result.append(.text(String(text[last..<match.range.lowerBound]))) }
            result.append(.variable(raw: String(text[match.range]), name: String(match.name)))
            last = match.range.upperBound
        }
        if last < text.endIndex { result.append(.text(String(text[last...]))) }
        return result
    }

    /// Değişkenlerin metindeki yeri (UTF-16, `NSString` aralığı) ve adı.
    /// Metin düzenleyicide (adres alanı) renk ve tıklama aralığı buradan;
    /// `segments` ile aynı kural.
    public static func variableRanges(in text: String) -> [(range: NSRange, name: String)] {
        guard containsVariable(text) else { return [] }
        return TemplateScanner.matches(in: text).map { match in
            (NSRange(match.range, in: text), String(match.name))
        }
    }

    public static func preview(
        for name: String,
        environment: EnvironmentModel?,
        tokenVariables: [(variable: String, requestName: String)],
        secretNames: [String]
    ) -> Preview {
        if name.hasPrefix("secret:") {
            let secret = String(name.dropFirst("secret:".count)).trimmingCharacters(in: .whitespaces)
            return .secret(name: secret, exists: secretNames.contains(secret))
        }
        if let token = tokenVariables.first(where: { $0.variable == name }) {
            return .token(requestName: token.requestName)
        }
        if let environment,
           let entry = environment.variables.last(where: { $0.enabled && $0.key == name }) {
            return .environment(environmentName: environment.name, value: entry.value)
        }
        return .undefined(environmentName: environment?.name)
    }
}
