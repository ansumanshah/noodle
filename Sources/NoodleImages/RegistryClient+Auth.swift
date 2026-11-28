import Foundation
import CFNetwork
import NoodleCore

extension RegistryClient {
    // MARK: auth

    nonisolated static func isLoopback(_ host: String) -> Bool {
        let h = host.split(separator: ":").first.map(String.init) ?? host
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h.hasSuffix(".localhost")
    }

    /// True when `host` is a loopback address or the Mac holds credentials for it, so only the Mac can pull from it reliably.
    public func isHostOnly(_ ref: ImageReference) async -> Bool {
        if ref.isLocalHTTPAllowed { return true }
        return await config.credential(forRegistry: ref.registryHost) != nil
    }

    public func setProxy(_ settings: ProxySettings) {
        transport.setProxy(settings)
        challenges.removeAll(); tokens.removeAll(); schemeForHost.removeAll()
    }

    /// Check credentials against a registry, the way `docker login` does: answer the `/v2/` challenge and see whether it accepts.
    public func login(serverAddress: String, credential: RegistryCredential) async throws {
        var host = serverAddress
        if let r = host.range(of: "://") { host = String(host[r.upperBound...]) }
        host = String(host.split(separator: "/").first ?? "")
        guard !host.isEmpty else { throw ImageError.invalid("missing registry address") }
        if host == ImageReference.hubDomain || host == "index.docker.io" { host = ImageReference.hubRegistryHost }
        let (scheme, h) = await base(host: host, localHTTP: Self.isLoopback(host) || host.hasSuffix(".localhost"))
        challenges[h] = nil; clearTokens(host: h)
        let auth = try await authorization(scheme: scheme, host: h, scope: "", credential: credential)
        guard let url = URL(string: "\(scheme)://\(h)/v2/") else { throw ImageError.invalid("bad registry address") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        if let auth { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await transport.data(req)
        switch resp.statusCode {
        case 200: return
        case 401, 403: throw ImageError.unauthorized("login attempt to \(scheme)://\(h)/v2/ failed with status: \(resp.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: resp.statusCode))")
        default: throw fail(resp, data, what: "login to \(h)")
        }
    }

    private func parseChallenge(_ header: String) -> Challenge? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { return Challenge(scheme: trimmed.lowercased(), realm: nil, service: nil) }
        let scheme = String(trimmed[..<space]).lowercased()
        var realm: String?, service: String?
        let rest = String(trimmed[trimmed.index(after: space)...])
        var i = rest.startIndex
        while i < rest.endIndex {
            guard let eq = rest[i...].firstIndex(of: "=") else { break }
            let key = rest[i..<eq].trimmingCharacters(in: CharacterSet(charactersIn: ", "))
            var j = rest.index(after: eq)
            var value = ""
            if j < rest.endIndex, rest[j] == "\"" {
                j = rest.index(after: j)
                let close = rest[j...].firstIndex(of: "\"") ?? rest.endIndex
                value = String(rest[j..<close])
                i = close < rest.endIndex ? rest.index(after: close) : close
            } else {
                let comma = rest[j...].firstIndex(of: ",") ?? rest.endIndex
                value = String(rest[j..<comma]); i = comma
            }
            if key == "realm" { realm = value } else if key == "service" { service = value }
        }
        return Challenge(scheme: scheme, realm: realm, service: service)
    }

    private func challenge(scheme: String, host: String) async throws -> Challenge? {
        if let c = challenges[host] { return c }
        guard let url = URL(string: "\(scheme)://\(host)/v2/") else { throw ImageError.invalid("bad registry host \(host)") }
        let (_, resp) = try await transport.data(URLRequest(url: url, timeoutInterval: 20))
        var result: Challenge?
        if resp.statusCode == 401, let h = resp.value(forHTTPHeaderField: "WWW-Authenticate") { result = parseChallenge(h) }
        challenges[host] = .some(result)
        return result
    }

    /// registry.gitlab.com -> gitlab.com, registry.example.com -> git.example.com: same last two DNS labels, never an IP literal.
    /// shortcut: a short deny list of shared suffixes instead of the public-suffix list; add entries as hosts appear.
    private static let sharedSuffixes: Set<String> = [
        "co.uk", "com.au", "github.io", "gitlab.io", "herokuapp.com", "amazonaws.com", "azurewebsites.net",
        "appspot.com", "cloudfront.net", "pages.dev", "vercel.app", "netlify.app",
    ]
    static func sharesRegistryDomain(_ realm: String, _ registry: String) -> Bool {
        func labels(_ h: String) -> [Substring]? {
            let l = h.split(separator: ".", omittingEmptySubsequences: false)
            return l.count >= 2 && !l.contains("") && !l.allSatisfy({ $0.allSatisfy(\.isNumber) || $0.contains(":") }) && !h.contains(":") ? l : nil
        }
        guard let r = labels(realm), let g = labels(registry) else { return false }
        return r.suffix(2) == g.suffix(2) && !sharedSuffixes.contains(r.suffix(2).joined(separator: "."))
    }

    /// Authorization header value for `scope` (e.g. `repository:library/ubuntu:pull`), or nil when the registry is open.
    func authorization(scheme: String, host: String, scope: String, credential: RegistryCredential?) async throws -> String? {
        guard let ch = try await challenge(scheme: scheme, host: host) else { return nil }
        let cred: RegistryCredential?
        if let credential { cred = credential } else { cred = await config.credential(forRegistry: host) }
        if cred != nil && scheme != "https" && !Self.isLoopback(host) { throw ImageError.unauthorized("credentials require HTTPS") }

        if ch.scheme == "basic" {
            guard let u = cred?.username, let p = cred?.password else { return nil }
            return "Basic " + Data("\(u):\(p)".utf8).base64EncodedString()
        }
        guard ch.scheme == "bearer", let realm = ch.realm else { return nil }
        guard var comps = URLComponents(string: realm), comps.scheme?.lowercased() == "https",
              let realmHost = comps.host?.lowercased(), comps.user == nil, comps.password == nil, comps.fragment == nil,
              let registryURL = URL(string: "https://\(host)"),
              (realmHost == registryURL.host?.lowercased() && (comps.port ?? 443) == (registryURL.port ?? 443) ||
               host == ImageReference.hubRegistryHost && realmHost == "auth.docker.io" && (comps.port ?? 443) == 443 ||
               // Registries backed by Docker Hub (docker.n8n.io) point at Hub's own realm. Anonymous pulls only: no credential
               // is ever sent to a realm the registry chose, so this cannot leak one.
               cred == nil && realmHost == "auth.docker.io" && (comps.port ?? 443) == 443 ||
               (comps.port ?? 443) == 443 && Self.sharesRegistryDomain(realmHost, registryURL.host?.lowercased() ?? "")) else {
            throw ImageError.unauthorized("untrusted token realm")
        }
        let tokenKey = [host, scope, cred?.username ?? "", cred?.password ?? "", cred?.identityToken ?? ""].joined(separator: "\u{1}")
        if let t = tokens[tokenKey], t.expires > Date() { return t.value }
        var items = comps.queryItems ?? []
        if let s = ch.service { items.append(URLQueryItem(name: "service", value: s)) }
        var req: URLRequest
        if let it = cred?.identityToken, !it.isEmpty {
            // OAuth2 refresh-token grant (POST), as docker does for identity tokens.
            guard let url = comps.url else { throw ImageError.unauthorized("invalid token realm") }
            req = URLRequest(url: url, timeoutInterval: 30)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var form = URLComponents()
            form.queryItems = [.init(name: "grant_type", value: "refresh_token"), .init(name: "refresh_token", value: it),
                               .init(name: "client_id", value: "noodle")]
                + (ch.service.map { [URLQueryItem(name: "service", value: $0)] } ?? [])
                + [URLQueryItem(name: "scope", value: scope)]
            req.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        } else {
            if !scope.isEmpty { items.append(URLQueryItem(name: "scope", value: scope)) }
            comps.queryItems = items
            guard let url = comps.url else { throw ImageError.unauthorized("invalid token realm") }
            req = URLRequest(url: url, timeoutInterval: 30)
            if let u = cred?.username, let p = cred?.password {
                req.setValue("Basic " + Data("\(u):\(p)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            }
        }
        let (data, resp) = try await transport.data(req)
        guard resp.statusCode == 200 else {
            throw ImageError.unauthorized("token endpoint returned \(resp.statusCode) for \(scope)")
        }
        struct Tok: Decodable { var token: String?; var access_token: String?; var expires_in: Int? }
        let tok = try JSONDecoder().decode(Tok.self, from: data)
        guard let value = tok.token ?? tok.access_token else { throw ImageError.unauthorized("no token in response") }
        let result = "Bearer " + value
        // Reuse until shortly before expiry (registries default to 60 s when they omit expires_in).
        let lifetime = TimeInterval(tok.expires_in ?? 60) - 10
        if lifetime > 0 { tokens[tokenKey] = (result, Date().addingTimeInterval(lifetime)) }
        return result
    }

    func clearTokens(host: String) {
        tokens = tokens.filter { !$0.key.hasPrefix(host + "\u{1}") }
    }

    func authorized(_ build: (String?) -> URLRequest, scheme: String, host: String, scope: String, credential: RegistryCredential?,
                            send: (URLRequest) async throws -> (Data, HTTPURLResponse)) async throws -> (Data, HTTPURLResponse) {
        var auth = try await authorization(scheme: scheme, host: host, scope: scope, credential: credential)
        var (data, resp) = try await send(build(auth))
        if resp.statusCode == 401 {
            challenges[host] = nil; clearTokens(host: host)
            auth = try await authorization(scheme: scheme, host: host, scope: scope, credential: credential)
            (data, resp) = try await send(build(auth))
        }
        return (data, resp)
    }

    func fail(_ resp: HTTPURLResponse, _ data: Data, what: String) -> ImageError {
        var msg = String(data: data.prefix(512), encoding: .utf8) ?? ""
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errs = obj["errors"] as? [[String: Any]], let m = errs.first?["message"] as? String { msg = m }
        if resp.statusCode == 401 || resp.statusCode == 403 { return .unauthorized("\(what): \(msg)") }
        if resp.statusCode == 404 { return .notFound("\(what)") }
        return .registry(status: resp.statusCode, message: "\(what): \(msg)")
    }
}
