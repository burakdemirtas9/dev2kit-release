import Foundation

/// XML, HTML, CSS, JavaScript, TypeScript (docs/V2.md step 1b).
///
/// Hepsi Format ve Minify taşıyor; fark yalnızca hangi biçimlendirici ve
/// doğrulayıcı. Tekrar etmesin diye ortak kurucu. İki eylemin ters dönüşümü
/// de "olduğu gibi": çıktı düzenlemesi girdiye aynen yansır (veri aynı).
///
/// Escape/Unescape YOK (kullanıcı kararı, 2026-10-18): kaçış kuralı bağlama
/// göre değişiyor (XML/HTML'de öznitelik, metin, CDATA, script; JS'de tırnak
/// türü, template literal; CSS'te seçici, değer); tek tip bir dönüşüm güvenli
/// bulunmadı. JSON'daki Escape/Unescape ayrı ve duruyor.
extension WorkbenchTools {
    public static let xml = textTool(
        id: "xml", title: "XML", syntax: .xml,
        keywords: ["soap", "wsdl", "pom", "biçimlendir", "sıkıştır", "doğrula"],
        format: { try MarkupFormatter.beautify($0, flavor: .xml, indent: $1.unit) },
        minify: { try MarkupTools.minify($0, html: false) },
        validate: MarkupTools.validateXML
    )

    public static let html = textTool(
        id: "html", title: "HTML", syntax: .html,
        keywords: ["web", "biçimlendir", "sıkıştır", "etiket"],
        format: { try MarkupFormatter.beautify($0, flavor: .html, indent: $1.unit) },
        minify: { try MarkupTools.minify($0, html: true) },
        validate: MarkupTools.checkHTML
    )

    public static let css = textTool(
        id: "css", title: "CSS", syntax: .css,
        keywords: ["style", "stil", "biçimlendir", "sıkıştır"],
        format: { try CSSFormatter.beautify($0, indent: $1.unit) },
        minify: { try CSSFormatter.minify($0) },
        validate: { StructureCheck.validate($0, rules: .css) }
    )

    public static let javascript = textTool(
        id: "javascript", title: "JavaScript", syntax: .javascript,
        keywords: ["js", "node", "ecmascript", "biçimlendir", "sıkıştır"],
        format: { try ScriptFormatter.beautify($0, indent: $1.unit) },
        minify: { try ScriptTools.minifyJavaScript($0) },
        validate: { StructureCheck.validate($0, rules: .javascript) }
    )

    /// JavaScript biçimlendiricisi üzerinden: tip açıklamaları ve generic'ler
    /// (`Map<string, number>`) `ScriptFormatter`'da ele alınıyor.
    public static let typescript = textTool(
        id: "typescript", title: "TypeScript", syntax: .javascript,
        keywords: ["ts", "tsx", "angular", "biçimlendir", "sıkıştır"],
        format: { try ScriptFormatter.beautify($0, indent: $1.unit) },
        minify: { try ScriptTools.minifyJavaScript($0, language: "TypeScript") },
        validate: { StructureCheck.validate($0, rules: .typescript) }
    )

    static func textTool(
        id: String,
        title: String,
        syntax: Beautifier.Kind,
        keywords: [String],
        format: @escaping @Sendable (String, Indentation) throws -> String,
        minify: @escaping @Sendable (String) throws -> String,
        validate: @escaping @Sendable (String) -> WorkbenchValidation
    ) -> WorkbenchTool {
        let actions = [
            WorkbenchAction(id: "format", title: "Format", usesIndentation: true,
                            reverse: { output, _, _ in output }) { input, options in
                try format(input, options.indentation)
            },
            WorkbenchAction(id: "minify", title: "Minify",
                            reverse: { output, _, _ in output }) { input, _ in
                try minify(input)
            },
        ]
        return WorkbenchTool(
            id: id,
            title: title,
            category: .format,
            keywords: ["beautify", "pretty", "minify", "validate"] + keywords,
            syntax: syntax,
            actions: actions,
            validate: validate
        )
    }
}
