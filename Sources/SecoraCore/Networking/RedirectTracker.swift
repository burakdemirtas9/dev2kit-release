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
    /// Bu isteğe uygulanacak TLS malzemesi (kurum CA'sı, istemci kimliği).
    private let tlsProfile: ResolvedTLSProfile?
    private let lock = NSLock()
    private var recorded: [RedirectStep] = []
    private var stop: RedirectGuard.Decision.StopReason?

    init(policy: RedirectPolicy, credentialHeaders: [String], tlsProfile: ResolvedTLSProfile? = nil) {
        self.policy = policy
        self.credentialHeaders = credentialHeaders
        self.tlsProfile = tlsProfile
    }

    /// TLS challenge'ları. Doğrulamayı atlayan bir yol yoktur; ayrıntı için
    /// TLSChallengeHandler.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            let (disposition, credential) = TLSChallengeHandler.serverTrust(
                challenge: challenge,
                profile: tlsProfile
            )
            completionHandler(disposition, credential)
        case NSURLAuthenticationMethodClientCertificate:
            let (disposition, credential) = TLSChallengeHandler.clientCertificate(profile: tlsProfile)
            completionHandler(disposition, credential)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
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
            credentialHeaders: credentialHeaders
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
