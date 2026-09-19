import Foundation

/// Panodan yapıştırılan bir `curl` komutunu isteğe çevirir.
///
/// Tarayıcıların "Copy as cURL" çıktısı ve API dokümanlarındaki örnekler
/// hedeflenir. Desteklenmeyen bayraklar SESSİZCE yutulmaz — özellikle
/// güvenliği zayıflatanlar (`-k`, `--proxy`) uyarı olarak bildirilir.
public enum CurlImporter {
    public struct Result {
        public let request: RequestModel
        public let warnings: [String]
    }

    public struct ParseError: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func parse(_ command: String, name: String = "cURL İsteği") throws -> Result {
        let tokens = try ShellTokenizer.tokenize(command)
        guard !tokens.isEmpty else {
            throw ParseError(message: "Komut boş.")
        }

        var warnings: [String] = []
        var url: String?
        var explicitMethod: HTTPMethod?
        var headers: [KeyValueEntry] = []
        var dataParts: [String] = []
        var urlencodeParts: [(String, String)] = []
        var formParts: [(String, String)] = []
        var basicCredentials: String?
        var cookieHeader: String?
        var redirect = RedirectPolicy.default
        var timeout: TimeInterval?
        var dataAsQuery = false

        var index = 0
        // "curl" öneki isteğe bağlı: doküman örnekleri bazen onsuz gelir.
        if tokens[0].lowercased() == "curl" { index = 1 }

        /// Bayrağın değerini alır; `--flag=value` ve `--flag value` biçimleri.
        func value(for token: String, at position: inout Int) throws -> String {
            if let equals = token.firstIndex(of: "="), token.hasPrefix("--") {
                return String(token[token.index(after: equals)...])
            }
            guard position + 1 < tokens.count else {
                throw ParseError(message: "\(token) bayrağının değeri eksik.")
            }
            position += 1
            return tokens[position]
        }

        func flagName(_ token: String) -> String {
            guard token.hasPrefix("--"), let equals = token.firstIndex(of: "=") else { return token }
            return String(token[token.startIndex..<equals])
        }

        while index < tokens.count {
            let token = tokens[index]
            let flag = flagName(token)

            switch flag {
            case "-X", "--request":
                let raw = try value(for: token, at: &index).uppercased()
                if let method = HTTPMethod(rawValue: raw) {
                    explicitMethod = method
                } else {
                    warnings.append("Desteklenmeyen metot \"\(raw)\"; GET olarak alındı.")
                }

            case "-H", "--header":
                let raw = try value(for: token, at: &index)
                if let separator = raw.firstIndex(of: ":") {
                    let key = String(raw[raw.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
                    let headerValue = String(raw[raw.index(after: separator)...])
                        .trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty {
                        headers.append(KeyValueEntry(key: key, value: headerValue))
                    }
                } else {
                    warnings.append("\"\(raw)\" başlığı \"Ad: değer\" biçiminde değil, atlandı.")
                }

            case "-d", "--data", "--data-raw", "--data-ascii", "--data-binary":
                dataParts.append(try value(for: token, at: &index))

            case "--data-urlencode":
                let raw = try value(for: token, at: &index)
                if let separator = raw.firstIndex(of: "=") {
                    urlencodeParts.append((
                        String(raw[raw.startIndex..<separator]),
                        String(raw[raw.index(after: separator)...])
                    ))
                } else {
                    urlencodeParts.append((raw, ""))
                }

            case "-F", "--form", "--form-string":
                let raw = try value(for: token, at: &index)
                if let separator = raw.firstIndex(of: "=") {
                    let key = String(raw[raw.startIndex..<separator])
                    let fieldValue = String(raw[raw.index(after: separator)...])
                    if fieldValue.hasPrefix("@") || fieldValue.hasPrefix("<") {
                        warnings.append("\"\(key)\" alanı dosya yüklüyor; dosya desteği yok, alan atlandı.")
                    } else {
                        formParts.append((key, fieldValue))
                    }
                } else {
                    warnings.append("\"\(raw)\" form alanı \"ad=değer\" biçiminde değil, atlandı.")
                }

            case "-u", "--user":
                basicCredentials = try value(for: token, at: &index)

            case "-b", "--cookie":
                cookieHeader = try value(for: token, at: &index)

            case "--url":
                url = try value(for: token, at: &index)

            case "-L", "--location":
                redirect.follow = true

            case "--max-redirs":
                let raw = try value(for: token, at: &index)
                if let count = Int(raw) { redirect.maxRedirects = count }

            case "-m", "--max-time", "--connect-timeout":
                let raw = try value(for: token, at: &index)
                if let seconds = TimeInterval(raw) { timeout = seconds }

            case "-G", "--get":
                dataAsQuery = true

            case "-I", "--head":
                explicitMethod = .head

            case "-k", "--insecure":
                warnings.append("⚠︎ -k (sertifika doğrulamasını kapat) uygulanmadı: Secora TLS doğrulamasını devre dışı bırakmaz.")

            case "-x", "--proxy":
                _ = try? value(for: token, at: &index)
                warnings.append("⚠︎ --proxy desteklenmiyor, yok sayıldı.")

            case "-E", "--cert", "--key", "--cacert":
                _ = try? value(for: token, at: &index)
                warnings.append("⚠︎ İstemci sertifikası / özel CA henüz desteklenmiyor, yok sayıldı.")

            // Davranışı etkilemeyen ya da bizde zaten varsayılan olan bayraklar.
            case "--compressed", "-s", "--silent", "-S", "--show-error", "-v", "--verbose",
                 "-i", "--include", "-f", "--fail", "--no-buffer", "-#", "--progress-bar":
                break

            default:
                if token.hasPrefix("-") {
                    warnings.append("\"\(token)\" bayrağı tanınmadı, yok sayıldı.")
                } else if url == nil {
                    url = token
                } else {
                    warnings.append("Fazladan argüman \"\(token)\" yok sayıldı.")
                }
            }
            index += 1
        }

        guard let resolvedURL = url, !resolvedURL.isEmpty else {
            throw ParseError(message: "Komutta URL bulunamadı.")
        }

        var model = RequestModel(name: name, url: normalize(resolvedURL))
        model.options.redirect = redirect
        if let timeout { model.options.timeout = timeout }

        if let cookieHeader {
            headers.append(KeyValueEntry(key: "Cookie", value: cookieHeader))
        }

        // Auth: Authorization başlığı tanınırsa Auth sekmesine taşınır.
        var remainingHeaders: [KeyValueEntry] = []
        for header in headers {
            if header.key.lowercased() == "authorization",
               let auth = parseAuthorization(header.value) {
                model.auth = auth
                continue
            }
            remainingHeaders.append(header)
        }
        if let basicCredentials {
            let parts = basicCredentials.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            model.auth = .basic(
                username: String(parts.first ?? ""),
                password: parts.count > 1 ? String(parts[1]) : ""
            )
        }

        // Gövde
        let joinedData = dataParts.joined(separator: "&")
        if dataAsQuery, !joinedData.isEmpty {
            model.queryParams = parseFormPairs(joinedData)
        } else if !formParts.isEmpty {
            model.body = .multipartForm(fields: formParts.map { KeyValueEntry(key: $0.0, value: $0.1) })
        } else if !urlencodeParts.isEmpty {
            model.body = .formURLEncoded(fields: urlencodeParts.map { KeyValueEntry(key: $0.0, value: $0.1) })
        } else if !joinedData.isEmpty {
            let contentType = remainingHeaders
                .first { $0.key.lowercased() == "content-type" }?.value.lowercased()
            let trimmed = joinedData.trimmingCharacters(in: .whitespacesAndNewlines)
            if contentType?.contains("json") == true || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                model.body = .raw(content: joinedData, contentType: contentType ?? "application/json")
            } else if contentType?.contains("x-www-form-urlencoded") == true || looksLikeFormPairs(joinedData) {
                model.body = .formURLEncoded(fields: parseFormPairs(joinedData))
            } else {
                model.body = .raw(content: joinedData, contentType: contentType ?? "text/plain")
            }
        }

        model.headers = remainingHeaders
        model.method = explicitMethod ?? (hasBody(model) ? .post : .get)

        if containsCredential(model) {
            warnings.append("Komutta kimlik bilgisi var. Secrets'a ekleyip {{secret:isim}} ile referans vermen önerilir.")
        }
        return Result(request: model, warnings: warnings)
    }

    // MARK: - Yardımcılar

    private static func normalize(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains("://"), !trimmed.hasPrefix("{{") else { return trimmed }
        // curl şemasız adrese http varsayar; biz https tercih ediyoruz.
        return "https://" + trimmed
    }

    private static func parseAuthorization(_ value: String) -> AuthConfig? {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let scheme = parts[0].lowercased()
        let credential = String(parts[1])
        if scheme == "bearer" {
            return .bearer(token: credential)
        }
        if scheme == "basic",
           let decoded = Data(base64Encoded: credential),
           let text = String(data: decoded, encoding: .utf8),
           let separator = text.firstIndex(of: ":") {
            return .basic(
                username: String(text[text.startIndex..<separator]),
                password: String(text[text.index(after: separator)...])
            )
        }
        return nil
    }

    private static func looksLikeFormPairs(_ text: String) -> Bool {
        guard text.contains("="), !text.contains("\n") else { return false }
        return text.split(separator: "&").allSatisfy { $0.contains("=") }
    }

    private static func parseFormPairs(_ text: String) -> [KeyValueEntry] {
        text.split(separator: "&").compactMap { pair in
            guard let separator = pair.firstIndex(of: "=") else {
                return KeyValueEntry(key: String(pair), value: "")
            }
            let key = String(pair[pair.startIndex..<separator])
            let value = String(pair[pair.index(after: separator)...])
            return KeyValueEntry(
                key: key.removingPercentEncoding ?? key,
                value: value.removingPercentEncoding ?? value
            )
        }
    }

    private static func hasBody(_ model: RequestModel) -> Bool {
        switch model.body {
        case .none: return false
        case .raw(let content, _): return !content.isEmpty
        case .formURLEncoded(let fields), .multipartForm(let fields): return !fields.isEmpty
        }
    }

    private static func containsCredential(_ model: RequestModel) -> Bool {
        if model.auth != .none { return true }
        let suspicious = ["authorization", "cookie", "x-api-key", "api-key", "apikey", "x-auth-token", "token"]
        return model.headers.contains { header in
            suspicious.contains(header.key.lowercased()) && !header.value.isEmpty
        }
    }
}
