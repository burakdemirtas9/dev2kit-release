import Foundation

/// Bir servisin kaynak kodundan dışarıya giden HTTP çağrıları.
public struct OutboundCall: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable, CaseIterable {
        case feign = "Feign"
        case httpExchange = "HTTP Interface"
        case restTemplate = "RestTemplate"
        case webClient = "WebClient"
        case restClient = "RestClient"
    }

    /// Temel adresin nereden geldiği.
    public enum Origin: Hashable, Sendable {
        /// Ayar yer tutucusu: `partner.url` ya da varsayılanıyla `partner.url:http://x`.
        case property(String)
        /// Kodda yazılı adres.
        case literal(String)
        /// Bilinmiyor (servis keşfi, çalışma anında kurulan istemci).
        case unknown
    }

    public let source: Source
    public let client: String
    public let operation: String
    public let method: HTTPMethod
    /// Temel adres değişkeninin adı (`{{partner-customer}}`).
    public let baseVariable: String
    public let baseOrigin: Origin
    /// Değişkenden sonraki yol; çalışma anı değerleri `{{ad}}`.
    public let path: String
    public let query: [KeyValueEntry]
    public let headers: [KeyValueEntry]
    public let bodyType: String?
    public let bodySample: String?
    /// `dosya:satır`
    public let location: String
    /// Adresin tamamı koddan çözülebildi mi.
    public let isComplete: Bool

    public var id: String { "\(location)|\(operation)" }
}

public struct OutboundScanResult: Sendable {
    public let projectName: String
    public let calls: [OutboundCall]
    public let config: SpringConfig
    public let javaFileCount: Int
    public let notes: [String]
}

/// Kaynak koddan giden çağrıları bulur. Dosyalar yalnızca okunur; hiçbir şey
/// derlenmez, çalıştırılmaz, ağa çıkılmaz.
///
/// Burası yalnızca giriş noktası; iş parçaları ayrı dosyalarda:
///
///   JavaSource          yorum/metin ayıklama, parantez dengesi
///   ProjectIndex        dosyalar arası bilgi: sabitler, `@Value`, DTO'lar, bean'ler
///   URLExpression       adres ifadesinin çözümü ve `{{değişken}}` şablonuna çevrilmesi
///   DeclarativeClients  Feign ve HTTP Interface istemcileri (+ `Annotations`)
///   TemplateCalls       RestTemplate, WebClient, RestClient çağrıları
///   SpringConfig        application.yml/properties okuma
///   OutboundCollectionBuilder  bulunan çağrılardan koleksiyon kurma
public enum OutboundScanner {
    public enum ScanError: Error, LocalizedError {
        case notADirectory
        case noJavaSources

        public var errorDescription: String? {
            switch self {
            case .notADirectory: return L10n.t("outbound.notDirectory")
            case .noJavaSources: return L10n.t("outbound.noJava")
            }
        }
    }

    static let skippedDirectories: Set<String> = [".git", ".idea", ".gradle", ".mvn", "target", "build", "out", "node_modules", ".vscode", "bin"]
    static let maxFiles = 20_000
    static let maxFileBytes = 2 * 1024 * 1024
    static let maxTotalBytes = 150 * 1024 * 1024

    // MARK: - Klasör

    public static func scan(directory: URL) throws -> OutboundScanResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ScanError.notADirectory
        }
        var files: [(path: String, text: String)] = []
        var kotlinCount = 0
        var totalBytes = 0
        var truncated = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants])
        let rootPath = directory.standardizedFileURL.path

        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if values?.isDirectory == true {
                if skippedDirectories.contains(name) { enumerator?.skipDescendants() }
                continue
            }
            // Sembolik bağlar izlenmez: seçilen klasörün dışına çıkılmasın.
            if values?.isSymbolicLink == true { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            // Testlerdeki sahte istemciler ve test ayarları gerçek çağrılar değildir.
            if relative.contains("src/test/") { continue }
            let lower = name.lowercased()
            if lower.hasSuffix(".kt") { kotlinCount += 1; continue }
            let isJava = lower.hasSuffix(".java")
            let isConfig = (lower.hasPrefix("application") || lower.hasPrefix("bootstrap"))
                && (lower.hasSuffix(".yml") || lower.hasSuffix(".yaml") || lower.hasSuffix(".properties"))
            guard isJava || isConfig else { continue }
            let size = values?.fileSize ?? 0
            guard size <= maxFileBytes else { continue }
            guard files.count < maxFiles, totalBytes + size <= maxTotalBytes else { truncated = true; break }
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            totalBytes += size
            files.append((relative, String(decoding: data, as: UTF8.self)))
        }

        var result = try scan(files: files, projectName: directory.lastPathComponent)
        var notes = result.notes
        if kotlinCount > 0 { notes.append(L10n.plural("outbound.kotlin", count: kotlinCount)) }
        if truncated { notes.append(L10n.t("outbound.truncated", L10n.number(files.count))) }
        result = OutboundScanResult(projectName: result.projectName, calls: result.calls, config: result.config, javaFileCount: result.javaFileCount, notes: notes)
        return result
    }

    // MARK: - Dosyalar

    public static func scan(files: [(path: String, text: String)], projectName: String) throws -> OutboundScanResult {
        var config = SpringConfig()
        var sources: [JavaSource] = []
        for file in files {
            if file.path.lowercased().hasSuffix(".java") {
                sources.append(JavaSource(path: file.path, text: file.text))
            } else {
                config.load(fileName: (file.path as NSString).lastPathComponent, text: file.text)
            }
        }
        guard !sources.isEmpty else { throw ScanError.noJavaSources }

        let index = ProjectIndex(sources: sources)
        var calls: [OutboundCall] = []
        for source in sources {
            calls += DeclarativeClients.find(in: source, index: index)
            calls += TemplateCalls.find(in: source, index: index)
        }
        calls.sort { ($0.client, $0.operation, $0.location) < ($1.client, $1.operation, $1.location) }
        return OutboundScanResult(projectName: projectName, calls: calls, config: config, javaFileCount: sources.count, notes: [])
    }
}
