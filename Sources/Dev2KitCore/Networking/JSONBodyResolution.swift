import Foundation

/// JSON gövdedeki `{{değişken}}`lerin çözümü (kullanıcı kararı, 2026-10-28).
///
/// Değişken değeri metin olarak yerine konuyor; değerde `"`, sonda kalan
/// `\` ya da geçersiz bir kaçış (`C:\path`) varsa gönderilen JSON bozuluyor,
/// sunucu 400 dönüyordu. Kural bugünkü davranışı BOZMAZ:
///
/// 1. Gövde her zamanki gibi çözülür. Sonuç geçerli JSON ise bayt bayt
///    aynen gider (elle kaçışlanmış değerler de değişmez).
/// 2. Geçersizse düzeltme denenir: tırnak içindeki her `{{…}}` değeri tek
///    başına geçerli bir JSON metni içeriği değilse kaçışlanır; geçerliyse
///    (kullanıcının kendi kaçışı) olduğu gibi kalır. Tırnak dışındakiler
///    (sayı, true/false, JSON parçası) hiç değişmez.
/// 3. Düzeltilmiş gövde geçerli JSON ise o gider ve kaçışlanan değişkenler
///    bildirilir (yalnızca adlar). Değilse ilk sonuç gider: kullanıcının
///    bilerek bozduğu JSON da aynen gider, sunucu karar verir.
///
/// Yalnızca API Client'ın JSON gövdesi (içerik türünde `json`,
/// `RequestBodyComments.appliesTo` ile aynı ölçüt). Workbench'te değişken
/// yok; URL, header, form ve JSON olmayan gövdeler değişmez.
///
/// Bilinen sınır (bilinçli): değeri tırnağı kapatıp alan ekleyen değer
/// (`x", "admin": true, "y": "z`) geçerli JSON ürettiği için 1. adımda
/// aynen gider; bugünkü davranış değişmesin.
public enum JSONBodyResolution {
    public struct Result: Equatable, Sendable {
        /// Gönderilecek gövde.
        public let text: String
        /// Değeri kaçışlanan değişkenler, yazıldığı gibi (`ad`, `secret:ad`);
        /// değer asla yok. Gövde olduğu gibi gittiyse boş.
        public let escapedVariables: [String]
    }

    /// - Parameter sendable: Yorumları ayıklanmış gövde
    ///   (`RequestBodyComments.sendable`).
    public static func resolve(_ sendable: String, contentType: String, resolver: VariableResolver) throws -> Result {
        let plain = try resolver.resolve(sendable)
        guard RequestBodyComments.appliesTo(contentType: contentType),
              sendable.contains("{{"),
              !isValidJSON(plain)
        else { return Result(text: plain, escapedVariables: []) }

        let repaired = try repair(sendable, resolver: resolver)
        guard !repaired.escapedVariables.isEmpty, isValidJSON(repaired.text) else {
            return Result(text: plain, escapedVariables: [])
        }
        return repaired
    }

    /// Tırnak içindeki değerlerden JSON metni olarak geçersiz olanları
    /// kaçışlar. Tırnak takibi kaçışlı `\"`'yi tanır; şablonun kendisi
    /// taramaya katılmaz (atlanır).
    static func repair(_ text: String, resolver: VariableResolver) throws -> Result {
        let matches = TemplateScanner.matches(in: text)
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var escaped: [String] = []
        var inString = false
        var afterBackslash = false
        var index = text.startIndex
        var next = 0

        while index < text.endIndex {
            if next < matches.count, matches[next].range.lowerBound == index {
                let token = String(matches[next].name)
                let value = try resolver.resolveToken(token)
                if inString, !isValidStringContent(value) {
                    output += String(JSONValue.quoted(value).dropFirst().dropLast())
                    if !escaped.contains(token) { escaped.append(token) }
                } else {
                    output += value
                }
                index = matches[next].range.upperBound
                next += 1
                continue
            }
            let character = text[index]
            if inString {
                if afterBackslash {
                    afterBackslash = false
                } else if character == "\\" {
                    afterBackslash = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            }
            output.append(character)
            index = text.index(after: index)
        }
        return Result(text: output, escapedVariables: escaped)
    }

    static func isValidJSON(_ text: String) -> Bool {
        let data = Data(text.utf8)
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil
    }

    /// Değer, tırnakların arasına olduğu gibi konduğunda geçerli bir JSON
    /// metni mi (kullanıcının kendi kaçışı dahil).
    static func isValidStringContent(_ value: String) -> Bool {
        isValidJSON("\"" + value + "\"")
    }
}
