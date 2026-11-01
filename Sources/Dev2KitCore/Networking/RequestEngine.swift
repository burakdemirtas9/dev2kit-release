import Foundation
import Security

/// Gönderilmiş bir isteğin sonucu. Body ham byte olarak tutulur;
/// metin/JSON yorumlama UI katmanına bırakılır.
public struct ResponseData: Sendable {
    public let statusCode: Int
    public let headers: [(name: String, value: String)]
    public let body: Data
    public let duration: TimeInterval
    public let finalURL: URL?
    /// İzlenen yönlendirme zinciri (denetim izi).
    public let redirects: [RedirectStep]
    /// Zincir bir politika nedeniyle kesildiyse sebebi.
    public let redirectStop: RedirectGuard.Decision.StopReason?
    /// Bağlantının teknik künyesi (protokol, adresler, TLS, sertifika).
    /// Opsiyonel: metrikler gelmemiş olabilir, eski kayıtlarda hiç yok.
    public let network: NetworkInfo?
    /// Sürenin aşamalara dağılımı (DNS, TCP, TLS, bekleme, indirme).
    public let timing: ResponseTiming?
    /// Tel üzerindeki boyutlar (istek/yanıt, başlık/gövde ayrımıyla).
    public let size: TransferSize?
    /// Bu yanıtı getiren HTTPS bağlantısında sunucu sertifikası HİÇ
    /// doğrulanmadı mı (kullanıcının kapattığı doğrulama anahtarı).
    ///
    /// Yanıtla birlikte taşınıyor: sonradan bakan biri o yanıtın doğrulanmış
    /// bir kaynaktan gelip gelmediğini başka türlü bilemez.
    public let certificateValidationSkipped: Bool
    /// Yanıt `RequestEngine.maxResponseBytes`'ı aştı: indirme durduruldu,
    /// `body` yalnızca ilk kısım. Arayüz uyarır.
    public let bodyLimitExceeded: Bool
    /// Bu gönderimde dolu gövde metot (GET) yüzünden isteğe konmadı; gövde
    /// editörde duruyor. Arayüz yanıtın üstünde bildirir (sunucu yanıtına
    /// eklenmez). İstek kurulurken belirlenir, gönderilen isteği anlatır.
    public let requestBodyOmitted: Bool
    /// JSON gövde değişkenlerle geçersiz kaldığı için değeri kaçışlanan
    /// değişkenler (`JSONBodyResolution`; yalnızca adlar). Arayüz bildirir.
    public let requestBodyEscapedVariables: [String]

    public init(
        statusCode: Int,
        headers: [(name: String, value: String)],
        body: Data,
        duration: TimeInterval,
        finalURL: URL?,
        redirects: [RedirectStep] = [],
        redirectStop: RedirectGuard.Decision.StopReason? = nil,
        network: NetworkInfo? = nil,
        timing: ResponseTiming? = nil,
        size: TransferSize? = nil,
        certificateValidationSkipped: Bool = false,
        bodyLimitExceeded: Bool = false,
        requestBodyOmitted: Bool = false,
        requestBodyEscapedVariables: [String] = []
    ) {
        self.bodyLimitExceeded = bodyLimitExceeded
        self.requestBodyOmitted = requestBodyOmitted
        self.requestBodyEscapedVariables = requestBodyEscapedVariables
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.duration = duration
        self.finalURL = finalURL
        self.redirects = redirects
        self.redirectStop = redirectStop
        self.network = network
        self.timing = timing
        self.size = size
        self.certificateValidationSkipped = certificateValidationSkipped
    }

    public var bodyText: String? { String(data: body, encoding: .utf8) }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

public enum RequestEngineError: Error, LocalizedError {
    case invalidURL(String)
    case notHTTPResponse
    case notAuthorized(String)
    /// Kesin güvenlik engeli: istek gönderilmedi, kullanıcı geçersiz kılamaz.
    case securityBlocked([SecurityFinding])
    /// Onay bekleyen güvenlik uyarıları: istek gönderilmedi.
    case needsApproval([SecurityFinding])
    /// TLS doğrulaması başarısız; bağlantı bizim tarafımızdan reddedildi.
    case tlsRejected(host: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .securityBlocked(let findings), .needsApproval(let findings):
            return findings.map { "\($0.title): \($0.detail)" }.joined(separator: "\n")
        case .invalidURL(let url): return L10n.t("engine.invalidURL", url)
        case .notHTTPResponse: return L10n.t("engine.notHTTP")
        case .notAuthorized(let name):
            return L10n.t("engine.noToken", name)
        case .tlsRejected(let host, let reason):
            return """
            \(host) için TLS doğrulaması başarısız, bağlantı kurulmadı: \(reason)

            Sertifika doğrulaması atlanmaz. Sunucunun zincirini imzalayan kök \
            sertifikayı TLS > Güven Deposu'na ekle; sunucu istemci sertifikası \
            istiyorsa TLS > Host Profilleri'nden tanımla.
            """
        }
    }
}

/// URLSession tabanlı istek motoru.
/// Şablon çözümü (değişken + secret) gönderim anında yapılır; çözülmüş
/// değerler bu fonksiyonun dışına sızmaz ve loglanmaz.
public final class RequestEngine: @unchecked Sendable {
    /// Çerez kavanozu kapsamı. Her environment kendi izole oturumunu alır:
    /// Dev ortamında alınan oturum çerezi Prod isteğine taşınamaz.
    public struct Scope: Hashable, Sendable {
        let key: String
        public init(environmentID: UUID?) {
            // Token Factory, environment seçili değilken token'ı taşımak için
            // geçici bir environment kuruyor; o da "environment yok" sayılır,
            // yoksa token kullanan istekler ayrı bir çerez kavanozuna düşerdi.
            let bound = environmentID == TokenFactory.unboundEnvironmentID ? nil : environmentID
            self.key = bound?.uuidString ?? "default"
        }
    }

    // NOT: "bağlanılan IP adresini hata mesajına ekle" denendi ve ÇALIŞMIYOR.
    // Ölçüldü: TLS el sıkışması başarısız olduğunda URLSession işlem
    // metriklerini hiç vermiyor (hata anında da, 300 ms sonra da
    // `networkInfo` boş). Adres ancak bağlantı kurulabilmiş isteklerde var,
    // orada da zaten Network künyesinde gösteriliyor.

    /// Sunucu sertifikasıyla ilgili hata kodları. Bu hatalarda kullanıcıya
    /// sunucunun sertifikasının künyesi de gösteriliyor.
    static let tlsFailureCodes: Set<URLError.Code> = [
        .serverCertificateUntrusted,
        .serverCertificateHasBadDate,
        .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid,
        .secureConnectionFailed,
    ]

    /// Oturum anahtarı: kapsam + doğrulama modu.
    ///
    /// Doğrulamasız istekler AYRI oturumdan gider. Aynı oturum kullanılsaydı
    /// doğrulanmadan kurulan bağlantı havuzda kalır, anahtar kapatıldıktan
    /// sonraki istek el sıkışma olmadan (yani doğrulama olmadan) onu yeniden
    /// kullanırdı — üstelik yanıtta hiçbir uyarı olmadan. Ayrı oturum aynı
    /// zamanda ayrı çerez kavanozu demek: doğrulamasız bağlantıda alınan
    /// oturum çerezi doğrulamalı isteklere taşınmaz.
    private struct SessionKey: Hashable {
        let scope: Scope
        let skipsValidation: Bool
    }

    private let lock = NSLock()
    private var sessions: [SessionKey: URLSession] = [:]

    public init() {}

    /// Sunucu sertifikası doğrulaması uygulama genelinde kapalı mı.
    ///
    /// Bilerek kalıcı DEĞİL: AppState açılışta her zaman `false` ile başlatır.
    /// Açık unutulan bir anahtarın ertesi gün tüm istekleri korumasız
    /// göndermesinin gereği yok.
    // TODO(showcase): geçici kaçış kapısı. İleride host bazlı hale getirilecek
    // ya da tamamen kaldırılacak — bkz. TODO.md "Sertifika doğrulama anahtarı".
    public var skipCertificateValidation: Bool {
        get { trustSettings.skipValidation }
        set { updateTrust { $0.skipValidation = newValue } }
    }

    /// Güven ayarları tek kilit altında. Ana iş parçacığı yazarken
    /// yönlendirme hedefinin profili URLSession temsilci kuyruğunda
    /// okunuyordu (veri yarışı, güvenlik taraması N4). Gönderim başında bir
    /// kez kopyası alınır; uçan istek yarıda ayar değiştirmez.
    struct TrustSettings {
        var skipValidation = false
        var profiles: [TLSProfile] = []
        var certificates: [SecCertificate] = []
        var allowsLongValidity = false

        /// Değişince havuz boşaltılır; doğrulama anahtarı ayrı oturum seçtiği için sayılmaz.
        func needsFreshConnections(comparedTo old: TrustSettings) -> Bool {
            let der = { (list: [SecCertificate]) in list.map { SecCertificateCopyData($0) as Data } }
            return profiles != old.profiles || allowsLongValidity != old.allowsLongValidity
                // DER baytlarıyla: aynı dosya yeniden okununca yeni nesne gelir.
                || der(certificates) != der(old.certificates)
        }
    }

    private let trustLock = NSLock()
    private var storedTrust = TrustSettings()

    var trustSettings: TrustSettings {
        trustLock.lock(); defer { trustLock.unlock() }
        return storedTrust
    }

    private func updateTrust(_ change: (inout TrustSettings) -> Void) {
        trustLock.lock()
        let old = storedTrust
        change(&storedTrust)
        let refresh = storedTrust.needsFreshConnections(comparedTo: old)
        trustLock.unlock()
        if refresh { dropPooledConnections() }
    }

    /// Kapsamın oturumu. `ephemeral` yapılandırma çerezleri YALNIZCA bellekte
    /// tutar; oturum kimlik bilgileri diske hiç yazılmaz, uygulama kapanınca gider.
    func session(for scope: Scope, skipsValidation: Bool = false) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        return lockedSession(for: SessionKey(scope: scope, skipsValidation: skipsValidation))
    }

    /// Görev, oturum alınırken aynı kilit altında açılır. Arada
    /// `dropPooledConnections` oturumu kapatırsa kapanmış oturumda görev
    /// açmak yakalanamayan bir istisnayla uygulamayı çökertirdi (güvenlik
    /// taraması N5). Kapatma kilit bırakıldıktan sonra yapılır ve açılmış
    /// görevleri bitirir (`finishTasksAndInvalidate`).
    private func dataTask(with request: URLRequest, scope: Scope, skipsValidation: Bool) -> URLSessionDataTask {
        lock.lock(); defer { lock.unlock() }
        return lockedSession(for: SessionKey(scope: scope, skipsValidation: skipsValidation)).dataTask(with: request)
    }

    /// `lock` tutulurken çağrılır.
    private func lockedSession(for key: SessionKey) -> URLSession {
        if let existing = sessions[key] { return existing }
        let session = Self.makeSession(cookieStorage: nil)
        sessions[key] = session
        return session
    }

    /// `cookieStorage` verilirse o kavanoz devralınır (bkz. `dropPooledConnections`).
    private static func makeSession(cookieStorage: HTTPCookieStorage?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.urlCache = nil
        if let cookieStorage { config.httpCookieStorage = cookieStorage }
        return URLSession(configuration: config)
    }

    /// Havuzdaki bağlantıları bırakır; sonraki istekler yeni el sıkışmayla
    /// (yani güncel güven yapılandırmasıyla) doğrulanır.
    ///
    /// Neden gerekli: sertifika yalnızca el sıkışmada doğrulanıyor. Ölçüldü:
    /// CA güven deposundan kaldırıldıktan sonra da istekler havuzdaki eski
    /// bağlantıdan (`isReusedConnection == true`) geçmeye devam ediyordu;
    /// ancak uygulama kapatılıp açılınca hata geliyordu. "Artık güvenme"
    /// kararının hemen uygulanması gerekiyor.
    ///
    /// Oturumlar yeniden kurulur ama çerez kavanozu devralınır: güven ayarı
    /// değiştirmek kullanıcının oturum girişlerini silmemeli. Uçmakta olan
    /// istekler eski oturumda tamamlanır (`finishTasksAndInvalidate`).
    func dropPooledConnections() {
        lock.lock()
        let old = sessions
        sessions = old.mapValues { Self.makeSession(cookieStorage: $0.configuration.httpCookieStorage) }
        lock.unlock()
        old.values.forEach { $0.finishTasksAndInvalidate() }
    }

    /// Kapsamın açılmış oturumları (doğrulamalı ve varsa doğrulamasız).
    private func existingSessions(in scope: Scope) -> [URLSession] {
        lock.lock(); defer { lock.unlock() }
        return sessions.filter { $0.key.scope == scope }.map(\.value)
    }

    /// Kapsamdaki çerezleri listeler (denetim ekranı için). Doğrulamasız
    /// oturumun kavanozu da dahil: denetim ekranında saklı çerez olmamalı.
    public func cookies(in scope: Scope) -> [HTTPCookie] {
        existingSessions(in: scope).flatMap { $0.configuration.httpCookieStorage?.cookies ?? [] }
    }

    /// Kapsamdaki tüm çerezleri siler ("oturumu kapat"), iki kavanozda da.
    public func clearCookies(in scope: Scope) {
        for session in existingSessions(in: scope) {
            guard let storage = session.configuration.httpCookieStorage else { continue }
            storage.cookies?.forEach(storage.deleteCookie)
        }
    }

    /// Host bazlı TLS profilleri. Gönderimden önce çözülür ki dosya/parola
    /// hataları anlaşılır mesajla dönsün, TLS el sıkışma hatası olarak değil.
    ///
    /// Aşağıdaki üç güven ayarı DEĞİŞİNCE havuz boşaltılır (bkz.
    /// `dropPooledConnections`). Motorun içinde: çağıran taraf unutamasın.
    /// Değişmeyen atamada boşaltılmaz — TLS ekranı her açılışta depoyu
    /// yeniden yüklüyor, her seferinde bağlantıları koparmanın gereği yok.
    public var tlsProfiles: [TLSProfile] {
        get { trustSettings.profiles }
        set { updateTrust { $0.profiles = newValue } }
    }
    /// Kurum güven deposundaki CA'lar (cacerts dizini). Her istekte dosya
    /// okumamak için burada tutulur; değişince AppState yeniler.
    public var trustStoreCertificates: [SecCertificate] {
        get { trustSettings.certificates }
        set { updateTrust { $0.certificates = newValue } }
    }
    /// Zinciri güven deposundaki bir CA'ya çıkan sertifikalarda ömür üst
    /// sınırı aranmasın mı. Kullanıcının Güven Deposu'nda açık seçimi;
    /// public köklere çıkan zincirleri etkilemez.
    public var trustStoreAllowsLongValidity: Bool {
        get { trustSettings.allowsLongValidity }
        set { updateTrust { $0.allowsLongValidity = newValue } }
    }

    /// Host başına son görülen sunucu sertifikası.
    ///
    /// Sertifika yalnızca TLS el sıkışmasında görülür; bağlantı havuzdan
    /// yeniden kullanıldığında el sıkışma olmaz ve künye sertifikasız kalırdı.
    /// İlk bağlantıda görülen künye burada saklanıp sonraki yanıtlara eklenir.
    /// Yalnızca gösterim içindir — doğrulama el sıkışmada gerçek zincirle
    /// yapılır; güven ayarı değişince havuz boşaltıldığı için eski bir karar
    /// yeni ayarın yerine geçmez.
    private let certificateLock = NSLock()
    private var certificateCache: [String: CertificateSummary] = [:]

    private func rememberCertificate(_ summary: CertificateSummary, for host: String) {
        certificateLock.lock(); defer { certificateLock.unlock() }
        certificateCache[host] = summary
    }

    private func knownCertificate(for host: String) -> CertificateSummary? {
        certificateLock.lock(); defer { certificateLock.unlock() }
        return certificateCache[host]
    }

    /// Künyeyi tamamlar: el sıkışma olmadıysa (yeniden kullanılan bağlantı)
    /// sertifika host önbelleğinden gelir.
    private func networkInfo(from tracker: RedirectTracker, host: String?) -> NetworkInfo? {
        guard var info = tracker.networkInfo else { return nil }
        guard let host else { return info }
        if let captured = info.certificate {
            rememberCertificate(captured, for: host)
        } else if let known = knownCertificate(for: host) {
            info.certificate = known
        }
        return info
    }

    /// - Parameters:
    ///   - hostPolicy: Yönetici host politikası. Bilerek varsayılan değersiz:
    ///     her çağıran politikayı açıkça vermek zorunda, unutulup atlanamasın.
    ///   - approvedWarnings: Kullanıcının daha önce onayladığı uyarı anahtarları.
    public func send(
        _ model: RequestModel,
        environment: EnvironmentModel?,
        secretStore: SecretStore,
        hostPolicy: HostPolicyState,
        approvedWarnings: Set<String> = []
    ) async throws -> ResponseData {
        let resolver = VariableResolver(environment: environment, secretStore: secretStore)
        let built = try buildRequest(model, resolver: resolver)
        var urlRequest = built.request

        // Ağa çıkmadan önce: engel varsa hiç gönderilmez, onaylanmamış uyarı
        // varsa kullanıcıya sorulmak üzere durulur.
        let findings = RequestInspector.inspect(
            model: model,
            request: urlRequest,
            environment: environment,
            policy: hostPolicy
        )
        try RequestInspector.enforce(findings, approved: approvedWarnings)

        urlRequest.timeoutInterval = model.options.timeout
        // Çerez gönderimi istek başına kapatılabilir.
        urlRequest.httpShouldHandleCookies = model.options.sendCookies

        let scope = Scope(environmentID: environment?.id)
        // Gönderim boyunca tek değer: istek uçarken ayar değişirse oturum,
        // yönlendirme hedefinin profili ve yanıttaki iz birbirini tutmaz
        // hale gelmesin.
        let trust = trustSettings
        let skipsValidation = trust.skipValidation
        // İlk host'un profili şimdi yüklenir: dosya hatası gönderimden önce
        // görünsün. Yönlendirme hedefinin profili, hedef TLS istediğinde KENDİ
        // host'u için seçilir (güvenlik incelemesi F4, 2026-10-20: ilk host'un
        // kurum CA'sı ve istemci kimliği zincirdeki her host'a uygulanıyordu).
        let firstHost = urlRequest.url?.host
        let firstProfile = try resolveTLSProfile(for: urlRequest.url, resolver: resolver, trust: trust)
        let tracker = RedirectTracker(
            policy: model.options.redirect,
            credentialHeaders: RedirectGuard.merged(RedirectGuard.credentialHeaders(for: model) + built.credentialHeaders),
            hostPolicy: hostPolicy,
            tlsProfile: { [self] host in
                if host.caseInsensitiveCompare(firstHost ?? "") == .orderedSame { return firstProfile }
                return try resolveTLSProfile(for: URL(string: "https://\(host)"), resolver: resolver, trust: trust)
            }
        )
        let start = ContinuousClock.now
        var data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(
                dataTask(with: urlRequest, scope: scope, skipsValidation: skipsValidation),
                tracker: tracker
            )
        } catch let error as URLError where error.code == .cancelled {
            // URLSession, bizim `cancelAuthenticationChallenge`'ımızı kullanıcı
            // iptaliyle AYNI kodla (-999) raporluyor. Ayırt etmezsek güvenlik
            // gerekçeli bir red sessizce yutuluyor: kullanıcı ne hata ne yanıt
            // görüyor. Redde ait kayıt varsa gerçek sebep fırlatılır.
            if let rejection = tracker.rejection, rejection.isOurs {
                throw RequestEngineError.tlsRejected(
                    host: rejection.host,
                    reason: rejection.reason
                )
            }
            throw error   // gerçek iptal (⌘.) olduğu gibi geçer
        } catch let error as URLError where Self.tlsFailureCodes.contains(error.code) {
            // Reddeden SİSTEM. Mesajı ("sertifika geçersiz") kullanıcıya neyi
            // düzelteceğini söylemiyor; sunucunun sertifikasının hangi adlar
            // için geçerli olduğunu ekliyoruz. Karar değişmiyor, yalnızca
            // künye ekleniyor.
            guard let names = tracker.rejection?.presentedNames, let host = urlRequest.url?.host else {
                throw error
            }
            throw RequestEngineError.tlsRejected(
                host: host,
                reason: error.localizedDescription + L10n.t("trust.presentedNames", names)
            )
        }
        let elapsed = start.duration(to: .now)
        if tracker.bodyLimitExceeded { data = Self.trimmedToCharacterBoundary(data) }

        guard let http = response as? HTTPURLResponse else {
            throw RequestEngineError.notHTTPResponse
        }
        let headers: [(String, String)] = http.allHeaderFields.compactMap { key, value in
            guard let name = key as? String else { return nil }
            return (name, "\(value)")
        }.sorted { $0.0.lowercased() < $1.0.lowercased() }

        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        return ResponseData(
            statusCode: http.statusCode,
            headers: headers,
            body: data,
            duration: seconds,
            finalURL: http.url,
            redirects: tracker.steps,
            redirectStop: tracker.stopReason,
            network: networkInfo(from: tracker, host: http.url?.host ?? urlRequest.url?.host),
            timing: tracker.responseTiming,
            size: tracker.size,
            // Düz HTTP'de doğrulanacak sertifika yok; uyarı orada yanıltır.
            certificateValidationSkipped: skipsValidation
                && [urlRequest.url, http.url].contains { $0?.scheme?.lowercased() == "https" },
            bodyLimitExceeded: tracker.bodyLimitExceeded,
            requestBodyOmitted: built.omittedBody,
            requestBodyEscapedVariables: built.bodyEscapedVariables
        )
    }

    /// Yanıt gövdesinin üst sınırı (kullanıcı kararı, 2026-10-19: 50 MB;
    /// sık aşılırsa güncellenir). Aşan yanıtın indirmesi durdurulur, ilk
    /// kısmı gösterilir: 2 GB dönen bir uç nokta belleği doldurmasın.
    public static let maxResponseBytes = 50_000_000

    /// Tek parça indirme (`data(for:)`) tavan koyamıyor; Swift'in parça parça
    /// okuması (`AsyncBytes`) bayt bayt ilerlediği için 50 MB'ı 4,5 dakikada
    /// okudu (ölçüldü, 2026-10-19). Klasik veri görevi + görev temsilcisi:
    /// veri parça parça gelir, tavanda görev iptal edilir. Swift görevi iptal
    /// edilirse (⌘.) URLSession görevi de iptal edilir.
    func fetch(_ task: URLSessionDataTask, tracker: RedirectTracker) async throws -> (Data, URLResponse) {
        task.delegate = tracker
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                tracker.collectBody(limit: Self.maxResponseBytes, continuation: continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Kesik gövde çok baytlı bir UTF-8 karakterin ortasında bitebilir; metne
    /// çevrilemez ve "ikili veri" sanılırdı. En çok 3 bayt geri çekilir.
    static func trimmedToCharacterBoundary(_ data: Data) -> Data {
        var trimmed = data
        for _ in 0..<3 where String(data: trimmed, encoding: .utf8) == nil && !trimmed.isEmpty {
            trimmed.removeLast()
        }
        return String(data: trimmed, encoding: .utf8) == nil ? data : trimmed
    }

    // İç kurgu ayrı fonksiyonda: URL/header/auth üretimi network'süz test edilebilsin.
    func buildURLRequest(_ model: RequestModel, resolver: VariableResolver) throws -> URLRequest {
        try buildRequest(model, resolver: resolver).request
    }

    /// İsteği kurar; dolu gövde metot yüzünden dışarıda bırakıldıysa
    /// `omittedBody`, JSON gövdede değeri kaçışlanan değişkenler
    /// `bodyEscapedVariables` (yanıttaki bildirimler buradan, gönderilen isteğe göre).
    func buildRequest(_ model: RequestModel, resolver: VariableResolver) throws
        -> (request: URLRequest, omittedBody: Bool, credentialHeaders: [String], bodyEscapedVariables: [String]) {
        // Yönlendirmede başka kaynağa taşınmayacak başlıklar. ÇÖZÜLMÜŞ haliyle
        // belirlenir (ham modelden değil): değişkenle verilen başlık adı,
        // secret'a çıkan environment değişkeni ve boşluklu referans da yakalanır
        // (güvenlik incelemesi F1, 2026-10-20).
        var credentialHeaders: [String] = []
        let templateURL = model.url.trimmingCharacters(in: .whitespaces)
        let resolvedURL = try resolver.resolveTrackingSecrets(templateURL)
        let resolvedURLString = resolvedURL.value
        // Hata mesajı ekranda ve kopyalanan metinde görünür: adres secret
        // içeriyorsa çözülmüş hali değil şablonu gösterilir (güvenlik taraması N7).
        let shownURL = resolvedURL.usesSecret ? templateURL : resolvedURLString
        guard var components = URLComponents(string: resolvedURLString),
              components.scheme != nil, components.host != nil else {
            throw RequestEngineError.invalidURL(shownURL)
        }

        var queryItems: [URLQueryItem] = []
        // Params tablosu adresle eşitleniyor (QueryParamSync): adreste zaten
        // olan parametre İKİ KEZ eklenmez. Parametresi yalnızca tabloda olan
        // eski kayıtlarda hepsi eklenir (geriye uyum).
        for entry in QueryParamSync.unrepresented(url: model.url, params: model.queryParams) {
            queryItems.append(URLQueryItem(
                name: try resolver.resolve(entry.key),
                value: try resolver.resolve(entry.value)
            ))
        }
        // Auth query param'a eklenecekse burada işlenir.
        if case .apiKey(let key, let value, .queryParam) = model.auth {
            queryItems.append(URLQueryItem(
                name: try resolver.resolve(key),
                value: try resolver.resolve(value)
            ))
        }
        // Adresteki sorgu dokunulmadan kalır; yalnızca eklenenler kodlanır.
        URLCodec.append(queryItems, to: &components)

        guard let url = components.url else {
            throw RequestEngineError.invalidURL(shownURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = model.method.rawValue

        // Kullanıcının User-Agent'ı yok sayılır: dev2kit kendi kimliğini
        // gönderir, ezilemez (Dev2KitIdentity).
        for entry in model.headers where entry.enabled && !entry.key.isEmpty && !Dev2KitIdentity.isUserAgent(entry.key) {
            let name = try resolver.resolveTrackingSecrets(entry.key)
            let value = try resolver.resolveTrackingSecrets(entry.value)
            try setHeader(value.value, named: name.value, on: &request)
            if name.usesSecret || value.usesSecret
                || HeaderClassifier.classify(name: name.value, value: value.value).sensitiveKind == .credential {
                credentialHeaders.append(name.value)
            }
        }

        switch model.auth {
        case .none, .apiKey(_, _, .queryParam):
            break
        case .basic(let username, let password):
            let credentials = "\(try resolver.resolve(username)):\(try resolver.resolve(password))"
            let encoded = Data(credentials.utf8).base64EncodedString()
            try setHeader("Basic \(encoded)", named: "Authorization", on: &request)
        case .bearer(let token):
            try setHeader("Bearer \(try resolver.resolve(token))", named: "Authorization", on: &request)
        case .apiKey(let key, let value, .header):
            let name = try resolver.resolve(key)
            try setHeader(try resolver.resolve(value), named: name, on: &request)
            credentialHeaders.append(name)
        case .oauth2(let config):
            guard let stored = try resolver.secret(named: config.tokenSecretName), !stored.isEmpty else {
                throw RequestEngineError.notAuthorized(config.name)
            }
            if let data = stored.data(using: .utf8),
               let token = try? JSONDecoder().decode(OAuth2Token.self, from: data) {
                try setHeader(token.authorizationHeaderValue, named: "Authorization", on: &request)
            } else {
                // cURL dışa aktarımında vault yerine placeholder gelir; aynen geçir.
                try setHeader("Bearer \(stored)", named: "Authorization", on: &request)
            }
        }

        var bodyEscapedVariables: [String] = []
        let omittedBody = try attachBody(to: &request, model: model, resolver: resolver, escapedVariables: &bodyEscapedVariables)
        // En sonda: Auth (API key başlığı) dahil hiçbir yol User-Agent'ı ezemez.
        Dev2KitIdentity.stamp(&request)
        return (request, omittedBody, credentialHeaders, bodyEscapedVariables)
    }

    /// Foundation satır sonu (CR/LF) içeren başlığı SESSİZCE düşürür: istek
    /// kimlik bilgisi olmadan gider ve kullanıcı nedenini göremez. Değer
    /// (secret ya da değişkenden gelmiş olabilir) burada çözülmüş haliyle
    /// denetlenir ve açık bir güvenlik engeli olarak durdurulur.
    private func setHeader(_ value: String, named name: String, on request: inout URLRequest) throws {
        if RequestInspector.containsHiddenCharacters(name, allowTab: false)
            || RequestInspector.containsHiddenCharacters(value, allowTab: true) {
            throw RequestEngineError.securityBlocked([RequestInspector.headerInjectionFinding(name)])
        }
        request.setValue(value, forHTTPHeaderField: name)
    }

    /// Gövdeyi bağlar. Metot gövde taşıyamıyorsa (GET) gövde HİÇ işlenmez:
    /// değişkenleri çözülmez, doğrulanmaz, isteğe konmaz; model (editördeki
    /// gövde) değişmez. Dönen değer: dolu bir gövde dışarıda bırakıldı mı.
    ///
    /// Eskiden GET + gövde `bodyNotAllowed` hatasıyla istek hiç gönderilmiyordu
    /// (kullanıcı isteği, 2026-10-20: GET gövdesiz gönderilsin, gövde korunsun).
    @discardableResult
    private func attachBody(
        to request: inout URLRequest,
        model: RequestModel,
        resolver: VariableResolver,
        escapedVariables: inout [String]
    ) throws -> Bool {
        guard model.method.allowsBody else {
            return model.body.hasSendableContent
        }
        switch model.body {
        case .none:
            return false

        case .raw(let content, let contentType):
            // Yorumlar yalnızca kullanıcı için; çözümden ÖNCE kalkar (yorumdaki
            // tanımsız {{değişken}} isteği durdurmasın).
            let sendable = RequestBodyComments.sendable(content, contentType: contentType)
            // JSON gövdede değişken değeri gövdeyi bozuyorsa yalnızca o değer
            // kaçışlanır; geçerli gövde bayt bayt aynı gider (JSONBodyResolution).
            let resolved = try JSONBodyResolution.resolve(sendable, contentType: contentType, resolver: resolver)
            let data = Data(resolved.text.utf8)
            guard !data.isEmpty else { return false }
            escapedVariables = resolved.escapedVariables
            setBody(data, contentType: contentType.isEmpty ? nil : contentType, on: &request)

        case .formURLEncoded(let fields):
            let query = URLCodec.formQuery(try fields
                .filter { $0.enabled && !$0.key.isEmpty }
                .map { URLQueryItem(name: try resolver.resolve($0.key), value: try resolver.resolve($0.value)) })
            guard !query.isEmpty else { return false }
            setBody(Data(query.utf8), contentType: "application/x-www-form-urlencoded", on: &request)

        case .multipartForm(let fields):
            let activeFields = fields.filter { $0.enabled && !$0.key.isEmpty }
            guard !activeFields.isEmpty else { return false }
            let boundary = "dev2kit-\(UUID().uuidString)"
            var data = Data()
            for field in activeFields {
                // Alan adındaki tırnak/backslash, Content-Disposition'ı bozmasın.
                // Satır sonu ise yeni bir parça başlığı açardı (değişkenden
                // gelen CR/LF, güvenlik taraması N8): tarayıcılar gibi %0D/%0A.
                let name = try resolver.resolve(field.key)
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\r", with: "%0D")
                    .replacingOccurrences(of: "\n", with: "%0A")
                data.append(Data("--\(boundary)\r\n".utf8))
                data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
                data.append(Data("\(try resolver.resolve(field.value))\r\n".utf8))
            }
            data.append(Data("--\(boundary)--\r\n".utf8))
            setBody(data, contentType: "multipart/form-data; boundary=\(boundary)", on: &request)
        }
        return false
    }

    /// Host'a uyan profili bulup sertifikalarını yükler.
    private func resolveTLSProfile(
        for url: URL?,
        resolver: VariableResolver,
        trust: TrustSettings
    ) throws -> ResolvedTLSProfile? {
        guard let host = url?.host else { return nil }
        let profile = TLSProfile.profile(for: host, in: trust.profiles)

        var certificates: [SecCertificate] = []
        var identity: SecIdentity?
        // CA seçilmemişken sabitleme ETKİSİZ sayılır (bkz. `pinsWithoutCA`):
        // aksi halde sabitlenecek çıpa olmadan güven deposu da düşüyor ve
        // CA'sı depodan gelen host'lar hata veriyordu.
        let pin = profile?.isPinningEffective ?? false

        if let profile {
            if profile.hasCA {
                certificates = try CertificateLoader.loadCertificates(atPath: profile.caCertificatePath)
            }
            if profile.hasClientCertificate {
                let password = try resolver.resolve(profile.clientCertificatePassword)
                identity = try CertificateLoader.loadIdentity(
                    atPath: profile.clientCertificatePath,
                    password: password
                )
            }
        }

        // Kurum güven deposu TÜM host'lara ek çıpa olarak uygulanır.
        // Sabitleme açıkken dahil edilmez: sabitleme, sabitleme demektir —
        // yoksa depoya bırakılan herhangi bir CA sabitlemeyi delerdi.
        if !pin {
            certificates.append(contentsOf: trust.certificates)
        }

        let resolved = ResolvedTLSProfile(
            caCertificates: certificates,
            pinToCA: pin,
            allowLongValidity: profile?.allowLongValidity ?? false,
            // Sabitleme açıkken depo zaten devre dışı; muafiyeti de taşımaz.
            longValidityAnchors: !pin && trust.allowsLongValidity ? trust.certificates : [],
            skipValidation: trust.skipValidation,
            identity: identity
        )
        return resolved.isEmpty ? nil : resolved
    }

    /// Gövdeyi isteğe bağlar (GET buraya hiç gelmez, bkz. `attachBody`).
    ///
    /// Eskiden GET/HEAD/OPTIONS için `httpBodyStream` kullanılıyordu ("URLSession
    /// httpBody'yi sessizce düşürür" varsayımıyla). Yerel bir dinleyiciye karşı
    /// ölçüldü (macOS 26 / Darwin 27): HEAD ve OPTIONS düz `httpBody` ile
    /// gövdeyi telde taşıyor, GET ise her üç yolda da reddediliyor.
    private func setBody(_ data: Data, contentType: String?, on request: inout URLRequest) {
        request.httpBody = data
        // Headers sekmesinde elle girilen Content-Type her zaman kazanır.
        if request.value(forHTTPHeaderField: "Content-Type") == nil, let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
    }
}
