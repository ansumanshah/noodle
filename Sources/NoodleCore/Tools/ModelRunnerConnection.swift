import Foundation

/// Standard upstream host/proxy settings, returned only through the private Docker socket.
public struct ModelRunnerConnection: Codable, Sendable {
    public let host: String
    public let proxy: String
    public init(host: String, proxy: String) { self.host = host; self.proxy = proxy }

    public var environment: [String: String] {
        ["MODEL_RUNNER_HOST": host, "HTTP_PROXY": proxy, "http_proxy": proxy,
         "NO_PROXY": "localhost,127.0.0.1,::1", "no_proxy": "localhost,127.0.0.1,::1"]
    }
}
