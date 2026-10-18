import Foundation

/// Dönüştürücüler (step 1e, docs/V2.md). Kullanıcı kararı (2026-10-18):
/// tek "Converter" yerine yön başına ayrı araç, kenar çubuğunda "Convert"
/// altında; bulmak ve aramak kolay.
///
/// Ters dönüşüm (çıktıyı düzenleyince girdi) YOK: dönüşüm kayıplı olabiliyor
/// (CSV'de tip, XML'de öznitelik sırası). Ağaç görünümü de yok: ağaç girdiden
/// kuruluyor, burada girdi JSON olmayabilir.
extension WorkbenchTools {
    public static let jsonToCSV = converter(
        id: "json-to-csv", title: "JSON → CSV", input: "JSON", syntax: .json, output: .plain,
        keywords: ["excel", "spreadsheet", "tablo", "table"],
        usesDelimiter: true,
        validate: JSONTool.validate,
        sample: #"[{ "id": 1, "name": "Ada", "city": "London" }, { "id": 2, "name": "Linus", "city": "Helsinki" }]"#
    ) { input, options in
        try CSVConverter.fromJSON(input, delimiter: options.csvDelimiter)
    }

    public static let csvToJSON = converter(
        id: "csv-to-json", title: "CSV → JSON", input: "CSV", syntax: .plain, output: .json,
        keywords: ["excel", "spreadsheet", "tablo", "table"],
        usesIndentation: true, usesDetectTypes: true,
        validate: CSVConverter.validate,
        sample: "id,name,city\n1,Ada,London\n2,Linus,Helsinki"
    ) { input, options in
        try CSVConverter.toJSON(input, detectTypes: options.detectTypes, indent: options.indentation.unit)
    }

    public static let jsonToXML = converter(
        id: "json-to-xml", title: "JSON → XML", input: "JSON", syntax: .json, output: .xml,
        keywords: ["soap"],
        usesIndentation: true, usesRootName: true,
        validate: JSONTool.validate,
        sample: #"{ "order": { "@id": "42", "item": ["api", "tools"] } }"#
    ) { input, options in
        try XMLConverter.fromJSON(input, rootName: options.xmlRootName, indent: options.indentation.unit)
    }

    public static let xmlToJSON = converter(
        id: "xml-to-json", title: "XML → JSON", input: "XML", syntax: .xml, output: .json,
        keywords: ["soap"],
        usesIndentation: true, usesDetectTypes: true,
        validate: MarkupTools.validateXML,
        defaultOptions: WorkbenchOptions(detectTypes: false),
        sample: #"<order id="42"><item>api</item><item>tools</item></order>"#
    ) { input, options in
        try XMLConverter.toJSON(input, detectTypes: options.detectTypes, indent: options.indentation.unit)
    }

    public static let jsonToYAML = converter(
        id: "json-to-yaml", title: "JSON → YAML", input: "JSON", syntax: .json, output: .plain,
        keywords: ["yml", "kubernetes", "k8s", "spring", "application.yml"],
        validate: JSONTool.validate,
        sample: #"{ "server": { "port": 8080 }, "country": "no", "profiles": ["dev", "prod"] }"#
    ) { input, _ in
        try YAMLWriter.fromJSON(input)
    }

    static func converter(
        id: String,
        title: String,
        input: String,
        syntax: Beautifier.Kind,
        output: Beautifier.Kind,
        keywords: [String],
        usesIndentation: Bool = false,
        usesDelimiter: Bool = false,
        usesDetectTypes: Bool = false,
        usesRootName: Bool = false,
        validate: @escaping @Sendable (String) -> WorkbenchValidation,
        defaultOptions: WorkbenchOptions = WorkbenchOptions(),
        sample: String,
        run: @escaping @Sendable (String, WorkbenchOptions) throws -> String
    ) -> WorkbenchTool {
        WorkbenchTool(
            id: id,
            title: title,
            inputName: input,
            category: .convert,
            keywords: ["convert", "dönüştür", "çevir"] + keywords,
            syntax: syntax,
            actions: [
                WorkbenchAction(id: "convert", title: "Convert", usesIndentation: usesIndentation,
                                usesDelimiter: usesDelimiter, usesDetectTypes: usesDetectTypes,
                                usesRootName: usesRootName, outputSyntax: output, run: run),
            ],
            validate: validate,
            defaultOptions: defaultOptions,
            sampleInput: sample
        )
    }
}
