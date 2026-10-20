import Foundation

/// `URLSession`'ın yönlendirme davranışını politikaya bağlar ve zinciri kaydeder.
///
/// Varsayılan davranışta URLSession yönlendirmeyi izlerken ilk isteğin
/// başlıklarını yeni hedefe taşır. Kaynak değiştiğinde `Authorization` ve
/// `Cookie` başlıkları burada kaldırılır; hangi başlığın neden düştüğü
/// `steps` içinde kullanıcıya gösterilmek üzere tutulur.
final class RedirectTracker: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let policy: RedirectPolicy
    /// Bu isteğe özgü kimlik taşıyan başlıklar (API key başlığı, secret referanslı başlıklar).
    private let credentialHeaders: [String]
    /// Yönlendirme hedefi de yönetici politikasına tabidir: izinli bir host
    /// 302 ile izinsiz bir host'a kaçış yolu olmasın.
    private let hostPolicy: HostPolicyState
    /// Host'a göre TLS malzemesi (kurum CA'sı, sabitleme, istemci kimliği).
    /// Her challenge, onu isteyen host için çözülür; yönlendirmede ilk host'un
    /// profili hedefe taşınmaz (F4). Sonuç host başına bir kez hesaplanır.
    private let tlsProfile: (String) throws -> ResolvedTLSProfile?
    private var tlsProfileCache: [String: Result<ResolvedTLSProfile?, Error>] = [:]
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
    /// Gövde toplama (`RequestEngine.fetch`): tavan aşılınca görev iptal edilir.
    private var body = Data()
    private var bodyLimit = Int.max
    private var limitExceeded = false
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

    init(
        policy: RedirectPolicy,
        credentialHeaders: [String],
        hostPolicy: HostPolicyState,
        tlsProfile: @escaping (String) throws -> ResolvedTLSProfile? = { _ in nil }
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
            let host = challenge.protectionSpace.host
            let profile: ResolvedTLSProfile?
            do {
                profile = try resolvedProfile(for: host)
            } catch {
                // Hedefin profili yüklenemedi (CA dosyası yok vb.): güvenle
                // devam edilemez, bağlantı reddedilir ve sebep gösterilir.
                lock.lock()
                tlsRejection = TLSChallengeHandler.Rejection(host: host, reason: error.localizedDescription, presentedNames: nil)
                lock.unlock()
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let (disposition, credential, rejection) = TLSChallengeHandler.serverTrust(
                challenge: challenge,
                profile: profile
            )
            if let rejection {
                lock.lock(); tlsRejection = rejection; lock.unlock()
            }
            completionHandler(disposition, credential)
        case NSURLAuthenticationMethodClientCertificate:
            // İstemci kimliği yalnızca KENDİ profili olan host'a sunulur.
            let profile = try? resolvedProfile(for: challenge.protectionSpace.host)
            let (disposition, credential) = TLSChallengeHandler.clientCertificate(profile: profile ?? nil)
            completionHandler(disposition, credential)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func resolvedProfile(for host: String) throws -> ResolvedTLSProfile? {
        let key = host.lowercased()
        lock.lock()
        if let cached = tlsProfileCache[key] {
            lock.unlock()
            return try cached.get()
        }
        lock.unlock()
        let result = Result { try tlsProfile(host) }
        lock.lock(); tlsProfileCache[key] = result; lock.unlock()
        return try result.get()
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

    // MARK: - Gövde toplama (tavanlı indirme)

    var bodyLimitExceeded: Bool {
        lock.lock(); defer { lock.unlock() }
        return limitExceeded
    }

    func collectBody(limit: Int, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        lock.lock(); defer { lock.unlock() }
        bodyLimit = limit
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let room = bodyLimit - body.count
        guard data.count > room else {
            body.append(data)
            lock.unlock()
            return
        }
        body.append(data.prefix(max(room, 0)))
        limitExceeded = true
        lock.unlock()
        // Tavan: indirme durur, ilk kısım yanıt olarak döner (hata değil).
        dataTask.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let collected = body
        let exceeded = limitExceeded
        lock.unlock()
        guard let pending else { return }
        if exceeded, let response = task.response {
            pending.resume(returning: (collected, response))
        } else if let error {
            pending.resume(throwing: error)
        } else if let response = task.response {
            pending.resume(returning: (collected, response))
        } else {
            pending.resume(throwing: URLError(.badServerResponse))
        }
    }
}
