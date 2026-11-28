import Foundation
import Darwin
import NoodleImages

// On demand in core. Only create reads these settings; stored container configs never change.
extension Engine {
    /// Environment is visible in Docker inspect. Refuse credentials instead of silently removing
    /// authentication. A caller's explicitly supplied environment remains their choice.
    static func proxyEnvironment(_ settings: ProxySettings) throws -> [String] {
        guard settings.injectIntoContainers, settings.mode != .off else { return [] }
        var values: [String: String] = [:]
        var exceptions = settings.exceptions
        if settings.mode == .custom {
            guard let raw = settings.url, let url = URLComponents(string: raw),
                  let endpoint = settings.endpoint else { return [] }
            guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw EngineError.badRequest("proxy injection cannot hide URL credentials from docker inspect; disable injection or use a proxy without credentials")
            }
            let value = try containerProxyURL(host: endpoint.host, port: endpoint.port)
            values["HTTP_PROXY"] = value
            values["HTTPS_PROXY"] = value
        } else {
            let system = SystemProxySettings.read()
            // PAC and discovery are per-request policies and cannot be represented by environment variables.
            if (system["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true ||
                (system["ProxyAutoDiscoveryEnable"] as? NSNumber)?.boolValue == true ||
                (system["SOCKSEnable"] as? NSNumber)?.boolValue == true {
                throw EngineError.badRequest("system automatic or SOCKS proxies cannot be injected; use a custom HTTP proxy or disable injection")
            }
            for scheme in ["HTTP", "HTTPS"] where (system[scheme + "Enable"] as? NSNumber)?.boolValue == true {
                guard system[scheme + "User"] == nil, system[scheme + "Password"] == nil,
                      system["ProxyUsername"] == nil, system["ProxyPassword"] == nil else {
                    throw EngineError.badRequest("proxy injection cannot hide credentials from docker inspect; disable injection")
                }
                guard let host = system[scheme + "Proxy"] as? String else {
                    throw EngineError.badRequest("system proxy has no host")
                }
                values[scheme + "_PROXY"] = try containerProxyURL(host: host, port: (system[scheme + "Port"] as? NSNumber)?.intValue ?? 80)
            }
            guard !values.isEmpty else { return [] }
            exceptions += system["ExceptionsList"] as? [String] ?? []
            if (system["ExcludeSimpleHostnames"] as? NSNumber)?.boolValue == true {
                throw EngineError.badRequest("system simple-hostname exceptions cannot be injected; use custom exceptions or disable injection")
            }
        }
        guard !values.isEmpty else { return [] }
        values["NO_PROXY"] = (["localhost", "127.0.0.1", "::1"] + exceptions.map {
            $0.hasPrefix("*.") ? String($0.dropFirst()) : $0
        }).joined(separator: ",")
        return ["HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"].flatMap { key -> [String] in
            // A system proxy may be configured for only one scheme; emit an empty value for the other.
            let value = values[key] ?? ""
            return [key + "=" + value, key.lowercased() + "=" + value]
        }
    }

    private static func containerProxyURL(host: String, port: Int) throws -> String {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !isLoopbackProxyHost(host) else {
            throw EngineError.badRequest("containers cannot reach a loopback-only proxy; listen on a non-loopback address or set proxy variables per container")
        }
        var url = URLComponents()
        url.scheme = "http"
        url.host = host.contains(":") ? "[" + host + "]" : host
        guard (1...65535).contains(port), !host.isEmpty,
              !host.contains(where: { $0.isWhitespace || "@/?#".contains($0) }) else {
            throw EngineError.badRequest("invalid proxy host or port for injection")
        }
        url.port = port
        guard let value = url.string else { throw EngineError.badRequest("invalid proxy host for injection") }
        return value
    }

    private static func isLoopbackProxyHost(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if name == "localhost" || name.hasSuffix(".localhost") { return true }
        // inet_aton also recognises abbreviated and integer IPv4 forms such as 127.1.
        var ipv4 = in_addr()
        if inet_aton(host, &ipv4) == 1 { return UInt32(bigEndian: ipv4.s_addr) >> 24 == 127 }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: &ipv6) { bytes in
            if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
            // IPv4-mapped loopback addresses must not bypass the IPv4 check.
            return bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255 && bytes[12] == 127
        }
    }

    func injectingProxy(into environment: [String]) throws -> [String] {
        var result = environment
        for variable in try Self.proxyEnvironment(proxy) {
            let key = String(variable.prefix(while: { $0 != "=" }))
            if !result.contains(where: { $0 == key || $0.hasPrefix(key + "=") }) { result.append(variable) }
        }
        return result
    }
}
