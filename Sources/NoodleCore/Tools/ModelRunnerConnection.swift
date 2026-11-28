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

    /// `env` plus the endpoint for a container that asked with `--gpus driver=noodle-models`.
    /// A name the container already sets is left alone. The key is in the URL, so the API key is a placeholder
    /// that OpenAI clients insist on.
    public func containerEnvironment(adding env: [String]) -> [String] {
        let set = Set(env.map { $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? $0 })
        let added = [("MODEL_RUNNER_HOST", host), ("OPENAI_BASE_URL", host + "/engines/v1"), ("OPENAI_API_KEY", "noodle")]
        return env + added.filter { !set.contains($0.0) }.map { $0.0 + "=" + $0.1 }
    }
}
