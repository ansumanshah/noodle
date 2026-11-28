import Foundation
import CFNetwork
import NoodleCore

/// Docker Registry v2 / OCI distribution client on URLSession.
public actor RegistryClient {
    let config: DockerConfig
    let transport: Transport
    struct Challenge { var scheme: String; var realm: String?; var service: String? }
    var challenges: [String: Challenge?] = [:]            // per host; .some(nil) = no auth needed
    var tokens: [String: (value: String, expires: Date)] = [:]   // per host + scope + identity
    var schemeForHost: [String: String] = [:]

    public init(config: DockerConfig = DockerConfig(), tempDirectory: URL) {
        self.config = config
        self.transport = Transport(tempDirectory: tempDirectory)
    }

    init(config: DockerConfig, tempDirectory: URL, sessionConfiguration: URLSessionConfiguration) {
        self.config = config
        self.transport = Transport(tempDirectory: tempDirectory, sessionConfiguration: sessionConfiguration)
    }

    // MARK: URL helpers

    func base(for ref: ImageReference) async -> (scheme: String, host: String) {
        await base(host: ref.registryHost, localHTTP: ref.isLocalHTTPAllowed)
    }

    func base(host: String, localHTTP: Bool) async -> (scheme: String, host: String) {
        if let s = schemeForHost[host] { return (s, host) }
        if localHTTP {
            // try https first, fall back to plain http for local dev registries
            if let url = URL(string: "https://\(host)/v2/"), (try? await transport.data(URLRequest(url: url, timeoutInterval: 3))) != nil {
                schemeForHost[host] = "https"
            } else {
                schemeForHost[host] = "http"
            }
            return (schemeForHost[host]!, host)
        }
        schemeForHost[host] = "https"
        return ("https", host)
    }

    nonisolated static func describe(_ error: Error) -> String {
        (error as? URLError)?.localizedDescription ?? "\(error)"
    }
}
