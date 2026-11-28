import Foundation
import CFNetwork
import NoodleCore

// MARK: - Transport

/// URLSession wrapper with progress and origin-bound credential redirects.
final class Transport: NSObject, URLSessionDownloadDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let tempDirectory: URL
    private let sessionConfiguration: URLSessionConfiguration?
    let lock = NSLock()
    struct Pending {
        var cont: CheckedContinuation<(URL, HTTPURLResponse), Error>?
        var uploadCont: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        var progress: (@Sendable (Int64, Int64) -> Void)?
        var movedTo: URL?
        var body = Data()
        var overflow = false
        var stream: BlobStream?
        var streamCont: CheckedContinuation<HTTPURLResponse, Error>?
    }
    var pending: [String: Pending] = [:]
    enum Route: Hashable { case system, direct, proxy }
    var sessions: [Route: URLSession] = [:]
    var proxy = ProxySettings()
    private var systemProxy: [String: Any] = [:]
    /// Requests in flight, and a counter that changes on every use so a delayed teardown can tell the session stayed idle.
    private var inFlight = 0
    private var useCount = 0
    private static let idleTeardown: TimeInterval = 30

    init(tempDirectory: URL, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.tempDirectory = tempDirectory
        self.sessionConfiguration = sessionConfiguration
        super.init()
    }

    static func key(_ session: URLSession, _ task: URLSessionTask) -> String {
        "\(UInt(bitPattern: ObjectIdentifier(session).hashValue)):\(task.taskIdentifier)"
    }

    /// Replace the proxy choice. Sessions in use finish their requests; new requests use the new choice.
    func setProxy(_ new: ProxySettings) {
        lock.lock()
        proxy = new
        let old = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        old.forEach { $0.finishTasksAndInvalidate() }
    }

    func route(for host: String?) -> Route {
        switch proxy.mode {
        case .system: return .system
        case .off: return .direct
        case .custom: return proxy.endpoint == nil || proxy.bypasses(host ?? "") ? .direct : .proxy
        }
    }

    /// Take the session for one request. Pair with `endUse()`.
    func beginUse(_ request: inout URLRequest) -> URLSession {
        var retiring: [URLSession] = []
        lock.lock(); defer {
            lock.unlock()
            retiring.forEach { $0.finishTasksAndInvalidate() }
        }
        inFlight += 1; useCount += 1
        if proxy.mode == .system {
            let current = SystemProxySettings.read()
            if !NSDictionary(dictionary: current).isEqual(to: systemProxy) {
                retiring = Array(sessions.values)
                sessions.removeAll()
                systemProxy = current
            }
        }
        let r = route(for: request.url?.host)
        // Plain-HTTP targets go to the proxy as absolute-URI requests, so send its credentials up front.
        // HTTPS targets use CONNECT and answer the proxy's challenge in the delegate.
        if r == .proxy, request.url?.scheme?.lowercased() == "http", let e = proxy.endpoint, let u = e.user, let p = e.password {
            request.setValue("Basic " + Data("\(u):\(p)".utf8).base64EncodedString(), forHTTPHeaderField: "Proxy-Authorization")
        }
        return makeSessionLocked(r)
    }

    /// When nothing is in flight, close the connection pool after a quiet spell. No timer runs while the session is unused.
    func endUse(releaseNow: Bool = false) {
        lock.lock()
        inFlight -= 1
        let idle = inFlight == 0
        let mark = useCount
        var closing: [URLSession] = []
        if idle && releaseNow { closing = Array(sessions.values); sessions.removeAll() }
        lock.unlock()
        closing.forEach { $0.finishTasksAndInvalidate() }
        guard idle, !releaseNow else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.idleTeardown) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            var stale: [URLSession] = []
            if self.inFlight == 0 && self.useCount == mark { stale = Array(self.sessions.values); self.sessions.removeAll() }
            self.lock.unlock()
            stale.forEach { $0.finishTasksAndInvalidate() }
        }
    }

    private func makeSessionLocked(_ route: Route) -> URLSession {
        if let s = sessions[route] { return s }
        let cfg = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        switch route {
        case .system: cfg.connectionProxyDictionary = systemProxy
        case .direct: cfg.connectionProxyDictionary = [:]
        case .proxy:
            if let e = proxy.endpoint {
                cfg.connectionProxyDictionary = [
                    "HTTPEnable": 1, "HTTPProxy": e.host, "HTTPPort": e.port,
                    "HTTPSEnable": 1, "HTTPSProxy": e.host, "HTTPSPort": e.port,
                    // No ExceptionsList: exceptions are applied in `route(for:)`. Any list, even an empty one,
                    // makes CFNetwork connect to loopback hosts directly.
                ]
            }
        }
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForResource = 24 * 3600
        cfg.httpAdditionalHeaders = ["User-Agent": "noodle/0.1 (darwin/arm64)"]
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        sessions[route] = s
        return s
    }

}
