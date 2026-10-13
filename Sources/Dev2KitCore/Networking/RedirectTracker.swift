import Foundation

/// `URLSession`'ın yönlendirme davranışını politikaya bağlar ve zinciri kaydeder.
///
/// Varsayılan davranışta URLSession yönlendirmeyi izlerken ilk isteğin
/// başlıklarını yeni hedefe taşır. Kaynak değiştiğinde `Authorization` ve
/// `Cookie` başlıkları burada kaldırılır; hangi başlığın neden düştüğü
/// `steps` içinde kullanıcıya gösterilmek üzere tutulur.
final class RedirectTracker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let policy: RedirectPolicy
    /// Bu isteğe özgü kimlik taşıyan başlıklar (API key başlığı, secret referanslı başlıklar).
    private let credentialHeaders: [String]
    /// Yönlendirme hedefi de yönetici politikasına tabidir: izinli bir host
    /// 302 ile izinsiz bir host'a kaçış yolu olmasın.
    private let hostPolicy: HostPolicyState
    /// Bu isteğe uygulanacak TLS malzemesi (kurum CA'sı, istemci kimliği).
    private let tlsProfile: ResolvedTLSProfile?
    private let lock = NSLock()
    private var recorded: [RedirectStep] = []
    private var stop: RedirectGuard.Decision.StopReason?
    /// Bağlantı künyesi: metrikler ve sunucu sertifikası iki ayrı callback'ten
    /// gelir, ikisi de burada birleşir.
    private var network = NetworkInfo()
    private var timing: ResponseTiming?
    /// TLS reddi. `-999` ile düşen isteğin gerçek sebebini motora taşır.
    private var tlsRejection: TLSChallengeHandler.Rejection?
    private var transferSize = TransferSize()

    init(
        policy: RedirectPolicy,
        credentialHeaders: [String],
        hostPolicy: HostPolicyState,
        tlsProfile: ResolvedTLSProfile? = nil
    ) {
        self.policy = policy
        self.credentialHeaders = credentialHeaders
        self.hostPolicy = hostPolicy
        self.tlsProfile = tlsProfile
    }

    /// TLS challenge'ları. Doğrulama yalnızca kullanıcının açık anahtarıyla
    /// atlanır; ayrıntı için TLSChallengeHandler.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            // Sunucunun sunduğu sertifikayı künye için al. Doğrulamayı bu
            // kayıt etkilemez; yalnızca kullanıcıya gösterilir.
            if let trust = challenge.protectionSpace.serverTrust,
               let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
               let leaf = chain.first {
                let summary = CertificateLoader.details(of: leaf)
                lock.lock(); network.certificate = summary; lock.unlock()
            }
            let (disposition, credential, rejection) = TLSChallengeHandler.serverTrust(
                challenge: challenge,
                profile: tlsProfile
            )
            if let rejection {
                lock.lock(); tlsRejection = rejection; lock.unlock()
            }
            completionHandler(disposition, credential)
        case NSURLAuthenticationMethodClientCertificate:
            let (disposition, credential) = TLSChallengeHandler.clientCertificate(profile: tlsProfile)
            completionHandler(disposition, credential)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// Bağlantı künyesi. URLSession bunu istek bittikten sonra bir kez verir;
    /// yönlendirme varsa SON işlemin metrikleri alınır — kullanıcıya gösterilen
    /// yanıt oradan geldi.
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        lock.lock(); defer { lock.unlock() }

        // Boyut TÜM işlemlerin toplamı: yönlendirme varsa her adımda da veri
        // gidip geldi, kullanıcıya gerçekte ne kadar taşındığı gösterilir.
        transferSize = metrics.transactionMetrics.reduce(TransferSize()) { total, step in
            total + TransferSize(
                requestHeaders: step.countOfRequestHeaderBytesSent,
                requestBody: step.countOfRequestBodyBytesSent,
                responseHeaders: step.countOfResponseHeaderBytesReceived,
                responseBody: step.countOfResponseBodyBytesReceived,
                responseBodyDecoded: step.countOfResponseBodyBytesAfterDecoding
            )
        }
        network.httpVersion = transaction.networkProtocolName
        network.localAddress = NetworkInfo.address(
            host: transaction.localAddress,
            port: transaction.localPort
        )
        network.remoteAddress = NetworkInfo.address(
            host: transaction.remoteAddress,
            port: transaction.remotePort
        )
        if let version = transaction.negotiatedTLSProtocolVersion {
            network.tlsProtocol = NetworkInfo.tlsProtocolName(version.rawValue)
        }
        if let suite = transaction.negotiatedTLSCipherSuite {
            network.cipherName = NetworkInfo.cipherName(suite.rawValue)
        }
        network.isReusedConnection = transaction.isReusedConnection
        network.isProxyConnection = transaction.isProxyConnection

        // Zaman kırılımı: aşamalara bölme kuralı Core'da (ResponseTiming),
        // burada yalnızca tarihler aktarılıyor.
        timing = ResponseTiming.make(
            taskStart: metrics.taskInterval.start,
            taskEnd: metrics.taskInterval.end,
            fetchStart: transaction.fetchStartDate,
            domainLookupStart: transaction.domainLookupStartDate,
            domainLookupEnd: transaction.domainLookupEndDate,
            connectStart: transaction.connectStartDate,
            connectEnd: transaction.connectEndDate,
            secureConnectionStart: transaction.secureConnectionStartDate,
            secureConnectionEnd: transaction.secureConnectionEndDate,
            requestStart: transaction.requestStartDate,
            requestEnd: transaction.requestEndDate,
            responseStart: transaction.responseStartDate,
            responseEnd: transaction.responseEndDate,
            isReusedConnection: transaction.isReusedConnection
        )
    }

    var responseTiming: ResponseTiming? {
        lock.lock(); defer { lock.unlock() }
        return timing
    }

    var size: TransferSize? {
        lock.lock(); defer { lock.unlock() }
        return transferSize.isEmpty ? nil : transferSize
    }

    var networkInfo: NetworkInfo? {
        lock.lock(); defer { lock.unlock() }
        return network.isEmpty ? nil : network
    }

    /// TLS reddi varsa sebebi. Motor `-999`'u buna bakarak yorumluyor.
    var rejection: TLSChallengeHandler.Rejection? {
        lock.lock(); defer { lock.unlock() }
        return tlsRejection
    }

    var steps: [RedirectStep] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var stopReason: RedirectGuard.Decision.StopReason? {
        lock.lock(); defer { lock.unlock() }
        return stop
    }

    /// Senkron (completion handler'lı) sürüm bilinçli tercih: delegate kuyruğunda
    /// çağrıldığı için kilit kullanımı async bağlam uyarısı üretmiyor.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let source = response.url, let destination = request.url else {
            completionHandler(request)
            return
        }

        lock.lock()
        defer { lock.unlock() }

        switch RedirectGuard.evaluate(
            from: source,
            to: destination,
            policy: policy,
            redirectCount: recorded.count,
            credentialHeaders: credentialHeaders,
            hostPolicy: hostPolicy
        ) {
        case .stop(let reason):
            stop = reason
            // nil: yönlendirme izlenmez, 3xx yanıtı olduğu gibi kullanıcıya döner.
            completionHandler(nil)

        case .follow(let strippedHeaders):
            var sanitized = request
            var actuallyStripped: [String] = []
            for header in strippedHeaders where sanitized.value(forHTTPHeaderField: header) != nil {
                sanitized.setValue(nil, forHTTPHeaderField: header)
                actuallyStripped.append(header)
            }
            recorded.append(
                RedirectStep(
                    statusCode: response.statusCode,
                    from: source,
                    to: destination,
                    strippedHeaders: actuallyStripped
                )
            )
            completionHandler(sanitized)
        }
    }
}
