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

    public static let jsonToXML = converter(
        id: "json-to-xml", title: "JSON → XML", input: "JSON", syntax: .json, output: .xml,
        keywords: ["soap"],
        usesIndentation: true, usesRootName: true,
        validate: JSONTool.validate,
        sample: #"{ "order": { "@id": "42", "item": ["api", "tools"] } }"#
    ) { input, options in
        try XMLConverter.fromJSON(input, rootName: options.xmlRootName, indent: options.indentation.unit)
    }

    public static let jsonToYAML = converter(
        id: "json-to-yaml", title: "JSON → YAML", input: "JSON", syntax: .json, output: .plain,
        keywords: ["yml", "kubernetes", "k8s", "spring", "application.yml"],
        validate: JSONTool.validate,
        sample: #"{ "server": { "port": 8080 }, "country": "no", "profiles": ["dev", "prod"] }"#
    ) { input, _ in
        try YAMLWriter.fromJSON(input)
    }

    /// YAML → Properties / Properties → YAML (Spring yapılandırması,
    /// 2026-10-20): `PropertiesConverter`.
    public static let yamlToProperties = converter(
        id: "yaml-to-properties", title: "YAML → Properties", input: "YAML", syntax: .plain, output: .plain,
        keywords: ["yml", "spring", "application.yml", "application.properties", "properties"],
        validate: YAMLReader.validate,
        sample: "server:\n  port: 8080\nspring:\n  application:\n    name: demo\n  profiles:\n    active:\n      - dev\n      - local"
    ) { input, _ in
        try PropertiesConverter.fromYAML(input)
    }

    public static let propertiesToYAML = converter(
        id: "properties-to-yaml", title: "Properties → YAML", input: "Properties", syntax: .plain, output: .plain,
        keywords: ["yml", "spring", "application.yml", "application.properties", "properties"],
        validate: PropertiesConverter.validate,
        sample: "server.port=8080\nspring.application.name=demo\nspring.profiles.active[0]=dev\nspring.profiles.active[1]=local"
    ) { input, _ in
        try PropertiesConverter.toYAML(input)
    }

    // MARK: Object Converter (JSON → sınıf/tip, `ObjectCodeGenerator`)

    static let objectSample = #"{ "id": 42, "customer_name": "Ada", "total": 12.5, "address": { "city": "İstanbul" }, "items": [{ "sku": "A1", "qty": 1 }] }"#

    static func objectConverter(id: String, title: String, language: ObjectCodeGenerator.Language,
                                output: Beautifier.Kind, keywords: [String]) -> WorkbenchTool {
        converter(
            id: id, title: title, input: "JSON", syntax: .json, output: output,
            keywords: ["dto", "class", "model", "sınıf", "pojo", "type"] + keywords,
            category: .objects,
            validate: JSONTool.validate,
            sample: objectSample
        ) { input, _ in
            try ObjectCodeGenerator.generate(input, language: language)
        }
    }

    public static let jsonToJava = objectConverter(
        id: "json-to-java", title: "JSON → Java DTO", language: .java, output: .javascript,
        keywords: ["java", "lombok", "spring", "record"])
    public static let jsonToKotlin = objectConverter(
        id: "json-to-kotlin", title: "JSON → Kotlin Data Class", language: .kotlin, output: .javascript,
        keywords: ["kotlin", "data class"])
    public static let jsonToSwift = objectConverter(
        id: "json-to-swift", title: "JSON → Swift Codable", language: .swift, output: .javascript,
        keywords: ["swift", "codable", "struct", "ios"])
    public static let jsonToTypeScriptInterface = objectConverter(
        id: "json-to-ts-interface", title: "JSON → TypeScript Interface", language: .typeScriptInterface, output: .javascript,
        keywords: ["typescript", "ts", "interface"])
    public static let jsonToTypeScriptType = objectConverter(
        id: "json-to-ts-type", title: "JSON → TypeScript Type", language: .typeScriptType, output: .javascript,
        keywords: ["typescript", "ts", "type alias"])
    public static let jsonToPython = objectConverter(
        id: "json-to-python", title: "JSON → Python Dataclass", language: .python, output: .plain,
        keywords: ["python", "dataclass", "py"])

    static func converter(
        id: String,
        title: String,
        input: String,
        syntax: Beautifier.Kind,
        output: Beautifier.Kind,
        keywords: [String],
        usesIndentation: Bool = false,
        usesDelimiter: Bool = false,
        usesRootName: Bool = false,
        category: WorkbenchTool.Category = .convert,
        validate: @escaping @Sendable (String) -> WorkbenchValidation,
        defaultOptions: WorkbenchOptions = WorkbenchOptions(),
        sample: String,
        run: @escaping @Sendable (String, WorkbenchOptions) throws -> String
    ) -> WorkbenchTool {
        WorkbenchTool(
            id: id,
            title: title,
            inputName: input,
            category: category,
            keywords: ["convert", "dönüştür", "çevir"] + keywords,
            syntax: syntax,
            actions: [
                WorkbenchAction(id: "convert", title: "Convert", usesIndentation: usesIndentation,
                                usesDelimiter: usesDelimiter,
                                usesRootName: usesRootName, outputSyntax: output, run: run),
            ],
            validate: validate,
            defaultOptions: defaultOptions,
            sampleInput: sample
        )
    }
}
