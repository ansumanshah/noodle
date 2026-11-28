import Foundation
import NoodleCore

extension Engine {
    /// Stat for the first real entry of a tar stream. Nil until the prefix holds that entry's header.
    /// Guest archives begin with a PAX record, so a stat must look past extended headers.
    public nonisolated static func pathStat(fromTarHeader h: Data) -> PathStat? {
        let b = [UInt8](h)
        var offset = 0, pax: [String: String] = [:], longName: String?, longLink: String?
        while offset + 512 <= b.count {
            let block = Array(b[offset..<(offset + 512)])
            guard !block.allSatisfy({ $0 == 0 }) else { return nil }
            func str(_ r: Range<Int>) -> String { String(decoding: block[r].prefix { $0 != 0 }, as: UTF8.self) }
            func oct(_ r: Range<Int>) -> Int64 { Int64(str(r).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0 }
            let type = block[156], size = oct(124..<136)
            if [UInt8(ascii: "x"), UInt8(ascii: "g"), UInt8(ascii: "L"), UInt8(ascii: "K")].contains(type) {
                guard size >= 0, size <= maxTarStatPrefix else { return nil }
                let end = offset + 512 + Int(size)
                guard end <= b.count else { return nil }
                let body = Array(b[(offset + 512)..<end])
                switch type {
                case UInt8(ascii: "x"): pax.merge(parsePAX(body)) { _, new in new }
                case UInt8(ascii: "L"): longName = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
                case UInt8(ascii: "K"): longLink = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
                default: break
                }
                offset = offset + 512 + (Int(size) + 511) / 512 * 512
                continue
            }
            let name = pax["path"] ?? longName ?? str(0..<100)
            let mtime = Date(timeIntervalSince1970: pax["mtime"].flatMap(TimeInterval.init) ?? TimeInterval(oct(136..<148)))
            var mode = UInt32(truncatingIfNeeded: oct(100..<108))
            if type == UInt8(ascii: "5") { mode |= 0x8000_0000 }
            if type == UInt8(ascii: "2") { mode |= 0x0800_0000 }
            let trimmed = name.hasSuffix("/") ? String(name.dropLast()) : name
            let base = (trimmed as NSString).lastPathComponent
            return PathStat(name: base.isEmpty ? name : base, size: pax["size"].flatMap(Int64.init) ?? size, mode: mode,
                            mtime: ISO8601.string(mtime), linkTarget: pax["linkpath"] ?? longLink ?? str(157..<257))
        }
        return nil
    }

    /// Most stream bytes a stat will read looking for the first real entry.
    public nonisolated static var maxTarStatPrefix: Int64 { 1 << 20 }

    /// PAX records: `<length> <key>=<value>\n`, where length counts the whole record.
    nonisolated static func parsePAX(_ body: [UInt8]) -> [String: String] {
        var out: [String: String] = [:], at = 0
        while at < body.count, let space = body[at...].firstIndex(of: 0x20),
              let length = Int(String(decoding: body[at..<space], as: UTF8.self)), length > space - at, at + length <= body.count {
            let record = body[(space + 1)..<(at + length - 1)]
            if let equals = record.firstIndex(of: 0x3D) {
                out[String(decoding: record[..<equals], as: UTF8.self)] = String(decoding: record[(equals + 1)...], as: UTF8.self)
            }
            at += length
        }
        return out
    }
}
