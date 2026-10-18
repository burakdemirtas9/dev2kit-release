import Foundation

/// Kodlayıcı / çözücü araçları (step 2a, kullanıcı kararı 2026-10-19):
/// JWT, Base64, URL, zaman damgası, UUID, hash/HMAC, hex. Hepsi yerel; ağa
/// çıkmaz. Base64, URL ve hex iki yönlü: çıktı düzenlenince girdi güncellenir.
extension WorkbenchTools {
    public static let jwt = WorkbenchTool(
        id: "jwt", title: "JWT Decoder", inputName: "JWT", category: .encode,
        keywords: ["token", "bearer", "jws", "claims", "exp", "çöz", "decode"],
        syntax: .plain,
        actions: [
            WorkbenchAction(id: "decode", title: "Decode", usesIndentation: true, outputSyntax: .json) { input, options in
                try JWTDecoder.decode(input, indent: options.indentation.unit)
            },
        ],
        validate: JWTDecoder.validate,
        sampleInput: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkFkYSIsImV4cCI6MTk5OTk5OTk5OX0.c2lnbmF0dXJl"
    )

    public static let base64 = WorkbenchTool(
        id: "base64", title: "Base64", category: .encode,
        keywords: ["encode", "decode", "kodla", "çöz", "basic auth"],
        syntax: .plain,
        actions: [
            WorkbenchAction(id: "encode", title: "Encode", usesURLSafe: true, outputSyntax: .plain,
                            reverse: { output, _, _ in
                                guard let data = Base64Codec.decode(output) else { throw WorkbenchIssue(message: "Base64 değil") }
                                return String(decoding: data, as: UTF8.self)
                            }) { input, options in
                Base64Codec.encode(Data(input.utf8), urlSafe: options.base64URLSafe)
            },
            WorkbenchAction(id: "decode", title: "Decode", usesURLSafe: true, outputSyntax: .plain,
                            reverse: { output, _, options in Base64Codec.encode(Data(output.utf8), urlSafe: options.base64URLSafe) }) { input, _ in
                guard let data = Base64Codec.decode(input) else {
                    throw WorkbenchIssue(message: "Base64 olarak çözülemedi (geçersiz karakter ya da uzunluk)")
                }
                return DecodedText.text(data)
            },
        ],
        sampleInput: "ZGV2MmtpdDpnaXpsaS1wYXJvbGE="
    )

    public static let url = WorkbenchTool(
        id: "url-encode", title: "URL Encode", category: .encode,
        keywords: ["percent", "yüzde", "query", "encode", "decode", "kodla", "çöz"],
        syntax: .plain,
        actions: [
            WorkbenchAction(id: "encode", title: "Encode", usesFormEncoding: true, outputSyntax: .plain,
                            reverse: { output, _, options in try URLCodec.decode(output, form: options.formEncoding) }) { input, options in
                URLCodec.encode(input, form: options.formEncoding)
            },
            WorkbenchAction(id: "decode", title: "Decode", usesFormEncoding: true, outputSyntax: .plain,
                            reverse: { output, _, options in URLCodec.encode(output, form: options.formEncoding) }) { input, options in
                try URLCodec.decode(input, form: options.formEncoding)
            },
        ],
        sampleInput: "https://api.example.com/callback?state=a b&next=/home"
    )

    public static let timestamp = WorkbenchTool(
        id: "timestamp", title: "Timestamp", category: .encode,
        keywords: ["unix", "epoch", "date", "time", "zaman", "tarih", "iso 8601", "millis"],
        syntax: .plain,
        actions: [
            WorkbenchAction(id: "convert", title: "Convert", runsOnEmptyInput: true, outputSyntax: .plain) { input, _ in
                try TimestampConverter.convert(input)
            },
        ],
        sampleInput: "1792352551428\n2026-10-19T18:30:00Z"
    )

    public static let uuid = WorkbenchTool(
        id: "uuid", title: "UUID", category: .encode,
        keywords: ["guid", "v4", "v7", "generate", "üret", "id"],
        syntax: .plain,
        actions: [
            WorkbenchAction(id: "v4", title: "Generate v4", usesCount: true, runsOnEmptyInput: true, outputSyntax: .plain) { _, options in
                UUIDTool.generate(version: 4, count: options.generateCount)
            },
            WorkbenchAction(id: "v7", title: "Generate v7", usesCount: true, runsOnEmptyInput: true, outputSyntax: .plain) { _, options in
                UUIDTool.generate(version: 7, count: options.generateCount)
            },
            WorkbenchAction(id: "inspect", title: "Inspect", outputSyntax: .plain) { input, _ in
                try UUIDTool.inspect(input)
            },
        ],
        sampleInput: "Generate ignores the input. For Inspect, paste UUIDs (one per line):\n0192e3a4-5b6c-7d8e-9f01-23456789abcd"
    )

    public static let hash = WorkbenchTool(
        id: "hash", title: "Hash / HMAC", category: .encode,
        keywords: ["sha256", "sha512", "sha1", "md5", "hmac", "signature", "imza", "digest", "özet"],
        syntax: .plain,
        actions: HashTool.Algorithm.allCases.map { algorithm in
            WorkbenchAction(id: algorithm.rawValue, title: algorithm.rawValue + (algorithm.isInsecure ? " ⚠︎" : ""),
                            usesHashOutput: true, usesHMACKey: algorithm.isHMAC, outputSyntax: .plain) { input, options in
                try HashTool.digest(input, algorithm: algorithm, key: options.hmacKey, output: options.hashOutput)
            }
        },
        sampleInput: #"{"event":"payment.completed","id":"pay_42"}"#
    )

    public static let hex = WorkbenchTool(
        id: "hex", title: "Hex", category: .encode,
        keywords: ["hexadecimal", "onaltılık", "bytes", "bayt", "encode", "decode"],
        syntax: .plain,
        actions: [
            WorkbenchAction(id: "encode", title: "Encode", outputSyntax: .plain,
                            reverse: { output, _, _ in String(decoding: try HexCodec.decode(output), as: UTF8.self) }) { input, _ in
                HexCodec.encode(Data(input.utf8))
            },
            WorkbenchAction(id: "decode", title: "Decode", outputSyntax: .plain,
                            reverse: { output, _, _ in HexCodec.encode(Data(output.utf8)) }) { input, _ in
                DecodedText.text(try HexCodec.decode(input))
            },
        ],
        sampleInput: "64 65 76 32 6b 69 74"
    )
}
