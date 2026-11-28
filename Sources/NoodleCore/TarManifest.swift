import Foundation

/// Content fingerprint of a tar stream, used by `noodle import` to prove a volume arrived byte-identical
/// with the same ownership and modes. Mtimes are left out on purpose: they are not stable across engines.
public enum TarManifest {
    public struct Malformed: Error, CustomStringConvertible {
        public let description: String
    }

    /// path -> "type mode uid gid size link sha256". Reads regular ustar, pax (x, g) and GNU long names (L, K).
    public static func manifest(of url: URL) throws -> [String: String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var entries: [String: String] = [:]
        var longName: String?, longLink: String?
        var pax: [String: String] = [:]

        func readExact(_ n: Int) throws -> Data {
            var data = Data()
            while data.count < n {
                guard let chunk = try handle.read(upToCount: n - data.count), !chunk.isEmpty else {
                    throw Malformed(description: "tar ended inside an entry")
                }
                data.append(chunk)
            }
            return data
        }
        func skip(_ n: Int) throws {
            var left = n
            while left > 0 { left -= try readExact(min(left, 1 << 20)).count }
        }

        while let header = try handle.read(upToCount: 512), !header.isEmpty {
            guard header.count == 512 else { throw Malformed(description: "short tar header") }
            if header.allSatisfy({ $0 == 0 }) { continue }
            let h = [UInt8](header)
            let flag = h[156] == 0 ? UInt8(ascii: "0") : h[156]
            var size = number(h[124..<136])
            let pad = { (n: Int) in (512 - n % 512) % 512 }

            if flag == UInt8(ascii: "x") || flag == UInt8(ascii: "g") || flag == UInt8(ascii: "L") || flag == UInt8(ascii: "K") {
                guard size >= 0, size <= 1 << 20 else { throw Malformed(description: "tar extended header too large") }
                let body = try readExact(size)
                try skip(pad(size))
                switch flag {
                case UInt8(ascii: "L"): longName = cString(body)
                case UInt8(ascii: "K"): longLink = cString(body)
                case UInt8(ascii: "x"): pax = parsePax(body)
                default: break
                }
                continue
            }
            var name = longName ?? pax["path"] ?? cString(h[0..<100])
            if longName == nil, pax["path"] == nil, cString(h[257..<262]) == "ustar", h[345] != 0 {
                name = cString(h[345..<500]) + "/" + name
            }
            let link = longLink ?? pax["linkpath"] ?? cString(h[157..<257])
            let uid = pax["uid"].flatMap(Int.init) ?? number(h[108..<116])
            let gid = pax["gid"].flatMap(Int.init) ?? number(h[116..<124])
            if let s = pax["size"].flatMap(Int.init) { size = s }
            let mode = number(h[100..<108]) & 0o7777
            var digest = ""
            if flag == UInt8(ascii: "0") || flag == UInt8(ascii: "7") {
                var hasher = Digest.Hasher()
                var left = size
                while left > 0 {
                    let chunk = try readExact(min(left, 1 << 20))
                    hasher.update(chunk)
                    left -= chunk.count
                }
                digest = hasher.finalize()
                try skip(pad(size))
            } else { size = 0 }
            var key = name
            while key.hasPrefix("./") { key.removeFirst(2) }
            while key.hasSuffix("/") && key.count > 1 { key.removeLast() }
            let type = String(UnicodeScalar(flag))
            entries[key] = "\(type) \(String(mode, radix: 8)) \(uid) \(gid) \(size) \(link) \(digest)"
            longName = nil; longLink = nil; pax = [:]
        }
        return entries
    }

    /// Human-readable differences, empty when identical. Capped so a bad import stays readable.
    public static func differences(_ a: [String: String], _ b: [String: String], limit: Int = 5) -> [String] {
        var out: [String] = []
        for key in Set(a.keys).union(b.keys).sorted() where a[key] != b[key] {
            out.append(a[key] == nil ? "extra in target: \(key)" : b[key] == nil ? "missing in target: \(key)" : "differs: \(key)")
            if out.count == limit { break }
        }
        return out
    }

    static func number(_ field: ArraySlice<UInt8>) -> Int {
        if let first = field.first, first & 0x80 != 0 {
            var v = Int(first & 0x7f)
            for byte in field.dropFirst() { v = v << 8 | Int(byte) }
            return v
        }
        let text = String(decoding: field.filter { $0 != 0 && $0 != 32 }, as: UTF8.self)
        return Int(text, radix: 8) ?? 0
    }

    static func cString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func parsePax(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let space = line.firstIndex(of: " "), let eq = line.firstIndex(of: "=") , space < eq else { continue }
            result[String(line[line.index(after: space)..<eq])] = String(line[line.index(after: eq)...])
        }
        return result
    }
}
