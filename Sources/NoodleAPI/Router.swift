import Foundation
import NIOHTTP1

public typealias Handler = @Sendable (Request, ResponseWriter) async throws -> Void

/// Route table. Patterns: `{name}` matches one segment, `*name` one or more (image names contain slashes).
struct RouteTable {
    enum Seg: Sendable { case lit(String), param(String), rest(String) }
    struct Route: Sendable {
        let method: HTTPMethod
        let segs: [Seg]
        let handler: Handler
    }
    private(set) var routes: [Route] = []

    mutating func add(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping Handler) {
        let segs: [Seg] = pattern.split(separator: "/").map { s in
            if s.hasPrefix("{"), s.hasSuffix("}") { return .param(String(s.dropFirst().dropLast())) }
            if s.hasPrefix("*") { return .rest(String(s.dropFirst())) }
            return .lit(String(s))
        }
        routes.append(Route(method: method, segs: segs, handler: handler))
    }
    mutating func get(_ p: String, _ h: @escaping Handler) { add(.GET, p, h) }
    mutating func post(_ p: String, _ h: @escaping Handler) { add(.POST, p, h) }
    mutating func put(_ p: String, _ h: @escaping Handler) { add(.PUT, p, h) }
    mutating func delete(_ p: String, _ h: @escaping Handler) { add(.DELETE, p, h) }
    /// A route whose handler returns nothing: replies `status` (204 by default) once `action` succeeds.
    mutating func action(_ method: HTTPMethod, _ p: String, status: HTTPResponseStatus = .noContent,
                         _ action: @escaping @Sendable (Request) async throws -> Void) {
        add(method, p) { req, w in try await action(req); try await w.empty(status) }
    }
    mutating func head(_ p: String, _ h: @escaping Handler) { add(.HEAD, p, h) }
}

public final class Router: Sendable {
    private let table: RouteTable

    init(table: RouteTable) { self.table = table }

    static func match(_ pat: ArraySlice<RouteTable.Seg>, _ path: ArraySlice<String>, _ params: inout [String: String]) -> Bool {
        guard let first = pat.first else { return path.isEmpty }
        switch first {
        case .lit(let s):
            guard path.first == s else { return false }
            return match(pat.dropFirst(), path.dropFirst(), &params)
        case .param(let n):
            guard let v = path.first, !v.contains("/") else { return false }   // a decoded %2F must not smuggle a path separator into an id
            params[n] = v
            return match(pat.dropFirst(), path.dropFirst(), &params)
        case .rest(let n):
            guard !path.isEmpty else { return false }
            for k in 1...path.count {
                var p = params
                p[n] = path.prefix(k).joined(separator: "/")
                if match(pat.dropFirst(), path.dropFirst(k), &p) { params = p; return true }
            }
            return false
        }
    }

    func find(_ method: HTTPMethod, _ segments: [String]) -> (Handler, [String: String])? {
        for r in table.routes where r.method == method {
            var params: [String: String] = [:]
            if Router.match(r.segs[...], segments[...], &params) { return (r.handler, params) }
        }
        return nil
    }

    /// Connections relayed from guest containers get the Docker API only: Noodle's own routes change the Mac side,
    /// and the model runner routes (`models`, `engines`, `logs`, Desktop's `exp` prefix) manage and run the Mac's models.
    static func relayRefusal(_ segments: [String]) -> APIError? {
        ["noodle", "exp", "models", "engines", "logs"].contains(segments.first ?? "")
            ? APIError(status: 403, message: "Noodle routes are not available to containers") : nil
    }

    func serve(_ request: Request, _ writer: ResponseWriter, relayed: Bool = false) async {
        var req = request
        do {
            if relayed, let refusal = Router.relayRefusal(req.segments) { throw refusal }
            try checkVersion(req.apiVersion)
            let method = req.method
            var found = find(method, req.segments)
            if found == nil, method == .HEAD { found = find(.GET, req.segments) }
            guard let (handler, params) = found else {
                throw APIError(status: 404, message: "page not found")
            }
            req.params = params
            try await handler(req, writer)
            await writer.finishIfNeeded()
        } catch {
            await writer.fail(error)
        }
    }

    private func checkVersion(_ v: String) throws {
        if Request.compare(v, APIInfo.apiVersion) > 0 {
            throw APIError(status: 400, message: "client version \(v) is too new. Maximum supported API version is \(APIInfo.apiVersion)")
        }
        if Request.compare(v, APIInfo.minAPIVersion) < 0 {
            throw APIError(status: 400, message: "client version \(v) is too old. Minimum supported API version is \(APIInfo.minAPIVersion), please upgrade your client to a newer version")
        }
    }
}
