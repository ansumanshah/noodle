import Foundation

/// Minimal tar reader (ustar + GNU long names + pax path). Enough for Docker's archive endpoint.
struct TarEntry: Sendable {
    var name: String
    var isDirectory: Bool
    var size: Int
    var data: Data
    /// Where the entry's body starts in the archive, so a caller can slice a mapped file with `keepData: false`.
    var offset = 0
    /// False when the archive ended before the advertised body did.
    var complete = true
}

enum Tar {
    static func entries(_ tar: Data, maxEntries: Int = 20_000, keepData: Bool = true) -> [TarEntry] {
        var out: [TarEntry] = []
        var off = tar.startIndex
        var longName: String?
        var paxSize: Int?
        while off + 512 <= tar.endIndex, out.count < maxEntries {
            let h = tar[off..<off + 512]
            if h.allSatisfy({ $0 == 0 }) { break }
            func field(_ r: Range<Int>) -> String {
                let s = h[(off + r.lowerBound)..<(off + r.upperBound)]
                return String(decoding: s.prefix { $0 != 0 }, as: UTF8.self)
            }
            let type = h[off + 156]
            let isMeta = [UInt8(ascii: "L"), UInt8(ascii: "x"), UInt8(ascii: "g")].contains(type)
            let size = (isMeta ? nil : paxSize) ?? Int(field(124..<136).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            if size < 0 { break }
            var name = field(0..<100)
            let prefix = field(345..<500)
            if !prefix.isEmpty { name = prefix + "/" + name }
            let bodyStart = off + 512
            let remaining = tar.endIndex - bodyStart
            let complete = size <= remaining
            let bodyEnd = bodyStart + min(size, remaining)
            // A body past the end stops the walk, so the padding sum cannot overflow.
            off = complete ? bodyStart + min(((size + 511) / 512) * 512, remaining) : tar.endIndex
            switch type {
            case UInt8(ascii: "L"):
                longName = String(decoding: tar[bodyStart..<bodyEnd].prefix { $0 != 0 }, as: UTF8.self)
            case UInt8(ascii: "x"):
                let text = String(decoding: tar[bodyStart..<bodyEnd], as: UTF8.self)
                for rec in text.split(separator: "\n") {
                    if let r = rec.range(of: " path=") { longName = String(rec[r.upperBound...]) }
                    if let r = rec.range(of: " size=") { paxSize = Int(rec[r.upperBound...]) ?? -1 }
                }
            case UInt8(ascii: "g"): break
            default:
                if let l = longName { name = l; longName = nil }
                paxSize = nil
                let isDir = type == UInt8(ascii: "5") || name.hasSuffix("/")
                out.append(TarEntry(name: name, isDirectory: isDir, size: size,
                                    data: keepData && !isDir ? Data(tar[bodyStart..<bodyEnd]) : Data(), offset: bodyStart, complete: complete))
            }
        }
        return out
    }
}
