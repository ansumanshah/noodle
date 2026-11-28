import Foundation
import NIOCore
import NIOHTTP1

/// An error that maps straight to an HTTP status and a Docker `{"message": ...}` body.
public struct APIError: Error, CustomStringConvertible, Sendable {
    public var status: Int
    public var message: String
    public init(status: Int, message: String) { self.status = status; self.message = message }
    public var description: String { message }
}

public struct Request: Sendable {
    public var method: HTTPMethod
    public var segments: [String]
    public var query: [String: [String]]
    public var headers: HTTPHeaders
    public var params: [String: String] = [:]
    public var apiVersion: String
    public let body: ByteInbox

    public func string(_ k: String) -> String? { query[k]?.last }
    public func all(_ k: String) -> [String] { query[k] ?? [] }
    public func int(_ k: String) -> Int? { string(k).flatMap { Int($0) } }
    public func bool(_ k: String, _ fallback: Bool = false) -> Bool {
        guard let v = string(k)?.lowercased() else { return fallback }
        if v.isEmpty { return fallback }
        return !(v == "0" || v == "false" || v == "no")
    }
    /// Unix seconds from `1700000000` or `1700000000.5`.
    public func seconds(_ k: String) -> Int64? { string(k).flatMap { Double($0) }.flatMap { $0.isFinite ? Int64(exactly: $0.rounded(.towardZero)) : nil } }
    public func param(_ k: String) -> String { params[k] ?? "" }

    /// API version >= `v` (e.g. "1.42").
    public func api(atLeast v: String) -> Bool { Request.compare(apiVersion, v) >= 0 }

    static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    /// Decode a size-limited JSON body. A bad body throws 400 `invalid` when given, else the raw DecodingError.
    public func decode<T: Decodable>(_ type: T.Type, limit: Int, invalid: String? = nil, emptyAsObject: Bool = false) async throws -> T {
        var data = try await body.readAll(limit: limit)
        if emptyAsObject, data.isEmpty { data = Data("{}".utf8) }
        guard let invalid else { return try JSONDecoder().decode(T.self, from: data) }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw APIError(status: 400, message: invalid) }
    }

    /// Decode a JSON body; an empty body yields nil.
    public func json<T: Decodable>(_ type: T.Type) async throws -> T? {
        let data = try await body.readAll(limit: 16 << 20)
        if data.isEmpty { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError(status: 400, message: "invalid JSON: \(error.localizedDescription)") }
    }
}

enum URLParts {
    static func split(uri: String) -> (path: String, query: String) {
        guard let q = uri.firstIndex(of: "?") else { return (uri, "") }
        return (String(uri[..<q]), String(uri[uri.index(after: q)...]))
    }

    static func segments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map { String($0).removingPercentEncoding ?? String($0) }
    }

    static func parseQuery(_ raw: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func dec(_ s: Substring) -> String {
                let p = s.replacingOccurrences(of: "+", with: " ")
                return p.removingPercentEncoding ?? p
            }
            out[dec(kv[0]), default: []].append(kv.count > 1 ? dec(kv[1]) : "")
        }
        return out
    }

    static func isVersionSegment(_ s: String) -> Bool {
        guard s.hasPrefix("v"), s.count > 1 else { return false }
        return s.dropFirst().allSatisfy { $0.isNumber || $0 == "." } && s.dropFirst().first?.isNumber == true
    }
}

enum APIInfo {
    static let apiVersion = "1.51"
    static let minAPIVersion = "1.24"
    static let serverVersion = "26.11.7"
}
