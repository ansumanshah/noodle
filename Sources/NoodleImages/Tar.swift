import Foundation

/// Minimal tar writer (ustar + GNU long names, base-256 sizes) used for `docker save` and `docker export` helpers.
public final class TarWriter {
    private let handle: FileHandle
    private let owns: Bool
    public private(set) var bytesWritten: Int64 = 0

    public init(handle: FileHandle, ownsHandle: Bool = false) { self.handle = handle; self.owns = ownsHandle }

    public convenience init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw POSIXError(.EIO) }
        self.init(handle: try FileHandle(forWritingTo: url), ownsHandle: true)
    }

    private func write(_ d: Data) throws { try handle.write(contentsOf: d); bytesWritten += Int64(d.count) }

    private func header(name: String, size: Int64, mode: Int, type: UInt8, mtime: Int64) -> Data {
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, _ off: Int, _ len: Int) { for (i, b) in s.utf8.prefix(len).enumerated() { h[off + i] = b } }
        func octal(_ v: Int64, _ off: Int, _ len: Int) {
            let s = String(v, radix: 8)
            let padded = String(repeating: "0", count: max(0, len - 1 - s.count)) + s
            put(padded, off, len - 1)
        }
        put(name, 0, 100)
        octal(Int64(mode), 100, 8); octal(0, 108, 8); octal(0, 116, 8)
        if size > 0o77777777777 {
            h[124] = 0x80
            var v = UInt64(size)
            for i in stride(from: 135, through: 125, by: -1) { h[i] = UInt8(v & 0xff); v >>= 8 }
        } else {
            octal(size, 124, 12)
        }
        octal(mtime, 136, 12)
        h[156] = type
        put("ustar", 257, 6); put("00", 263, 2)
        for i in 148..<156 { h[i] = 0x20 }
        let sum = h.reduce(0) { $0 + Int($1) }
        let cs = String(sum, radix: 8)
        put(String(repeating: "0", count: max(0, 6 - cs.count)) + cs, 148, 6)
        h[154] = 0; h[155] = 0x20
        return Data(h)
    }

    private func writeHeader(name: String, size: Int64, mode: Int, type: UInt8, mtime: Int64) throws {
        if name.utf8.count > 100 {
            let nameData = Data(name.utf8) + Data([0])
            try write(header(name: "././@LongLink", size: Int64(nameData.count), mode: 0, type: UInt8(ascii: "L"), mtime: 0))
            try write(nameData)
            try write(Data(count: pad(nameData.count)))
        }
        try write(header(name: name, size: size, mode: mode, type: type, mtime: mtime))
    }

    private func pad(_ n: Int) -> Int { (512 - n % 512) % 512 }

    public func addFile(_ name: String, data: Data, mode: Int = 0o644, mtime: Int64 = 0) throws {
        try writeHeader(name: name, size: Int64(data.count), mode: mode, type: UInt8(ascii: "0"), mtime: mtime)
        try write(data)
        try write(Data(count: pad(data.count)))
    }

    public func addFile(_ name: String, from url: URL, mode: Int = 0o644, mtime: Int64 = 0) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        try writeHeader(name: name, size: size, mode: mode, type: UInt8(ascii: "0"), mtime: mtime)
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var remaining = size
        while remaining > 0 {
            guard let chunk = try h.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty else { throw ImageError.io("short read \(url.path)") }
            try write(chunk); remaining -= Int64(chunk.count)
        }
        try write(Data(count: pad(Int(size))))
    }

    public func addDirectory(_ name: String, mode: Int = 0o755) throws {
        try writeHeader(name: name.hasSuffix("/") ? name : name + "/", size: 0, mode: mode, type: UInt8(ascii: "5"), mtime: 0)
    }

    public func finish() throws {
        try write(Data(count: 1024))
        if owns { try handle.close() }
    }
}

public struct TarEntry: Sendable {
    public var name: String
    public var size: Int64
    public var type: UInt8
    public var mode: Int
    public var linkName: String
    public var isFile: Bool { type == UInt8(ascii: "0") || type == 0 }
    public var isDirectory: Bool { type == UInt8(ascii: "5") }
    fileprivate var dataOffset: UInt64
}

/// Sequential tar reader on a file. Handles GNU long names (L) and PAX path/size (x).
public final class TarReader {
    private let handle: FileHandle
    private var position: UInt64 = 0
    private let length: UInt64

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        length = UInt64((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
    }
    deinit { try? handle.close() }

    private func readExact(_ n: Int) throws -> Data {
        guard n > 0 else { return Data() }
        guard let d = try handle.read(upToCount: n), d.count == n else { throw ImageError.io("truncated tar") }
        return d
    }

    private static func parseNumber(_ b: ArraySlice<UInt8>) throws -> Int64 {
        if let f = b.first, f & 0x80 != 0 {
            guard f & 0x40 == 0 else { throw ImageError.invalid("negative tar number") }
            var v = Int64(f & 0x7f)
            for x in b.dropFirst() {
                let (shifted, overflow) = v.multipliedReportingOverflow(by: 256)
                let (next, additionOverflow) = shifted.addingReportingOverflow(Int64(x))
                guard !overflow, !additionOverflow else { throw ImageError.invalid("tar number is too large") }
                v = next
            }
            return v
        }
        let s = String(decoding: b.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return 0 }
        guard s.utf8.allSatisfy({ (48...55).contains($0) }), let v = Int64(s, radix: 8) else {
            throw ImageError.invalid("invalid tar number")
        }
        return v
    }
    private static func parseString(_ b: ArraySlice<UInt8>) -> String { String(decoding: b.prefix { $0 != 0 }, as: UTF8.self) }

    private func endOfEntry(size: Int64, at offset: UInt64) throws -> UInt64 {
        guard size >= 0, offset <= length else { throw ImageError.invalid("invalid tar entry size") }
        let padded = (UInt64(size) + 511) / 512 * 512
        guard padded <= length - offset else { throw ImageError.io("truncated tar entry") }
        return offset + padded
    }

    public func next() throws -> TarEntry? {
        var longName: String?
        var paxPath: String?, paxSize: Int64?
        while true {
            if position == length { return nil }
            guard position <= length, length - position >= 512 else { throw ImageError.io("truncated tar header") }
            try handle.seek(toOffset: position)
            let hdr = [UInt8](try readExact(512))
            position += 512
            if hdr.allSatisfy({ $0 == 0 }) { return nil }
            var name = Self.parseString(hdr[0..<100])
            let size = try Self.parseNumber(hdr[124..<136])
            let type = hdr[156]
            let linkName = Self.parseString(hdr[157..<257])
            let mode = Int(try Self.parseNumber(hdr[100..<108]))
            if Self.parseString(hdr[257..<263]).hasPrefix("ustar") {
                let prefix = Self.parseString(hdr[345..<500])
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            let dataStart = position
            if type == UInt8(ascii: "L") {
                let end = try endOfEntry(size: size, at: dataStart)
                guard size <= 1 << 20 else { throw ImageError.invalid("tar long name is too large") }
                try handle.seek(toOffset: dataStart)
                let d = try readExact(Int(size))
                longName = Self.parseString([UInt8](d)[...])
                position = end
                continue
            }
            if type == UInt8(ascii: "x") {
                let end = try endOfEntry(size: size, at: dataStart)
                guard size <= 1 << 20 else { throw ImageError.invalid("tar metadata is too large") }
                try handle.seek(toOffset: dataStart)
                let d = try readExact(Int(size))
                for line in String(decoding: d, as: UTF8.self).split(separator: "\n") {
                    guard let sp = line.firstIndex(of: " ") else { continue }
                    let kv = line[line.index(after: sp)...]
                    if kv.hasPrefix("path=") { paxPath = String(kv.dropFirst(5)) }
                    if kv.hasPrefix("size=") {
                        let value = kv.dropFirst(5)
                        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                              let parsed = Int64(value) else { throw ImageError.invalid("invalid PAX size") }
                        paxSize = parsed
                    }
                }
                position = end
                continue
            }
            if type == UInt8(ascii: "g") { position = try endOfEntry(size: size, at: dataStart); continue }
            let realSize = paxSize ?? size
            position = try endOfEntry(size: realSize, at: dataStart)
            return TarEntry(name: longName ?? paxPath ?? name, size: realSize, type: type, mode: mode, linkName: linkName, dataOffset: dataStart)
        }
    }

    public func readData(_ e: TarEntry, limit: Int64 = 64 << 20) throws -> Data {
        guard e.size >= 0, e.size <= limit else { throw ImageError.invalid("tar entry \(e.name) too large to read in memory") }
        _ = try endOfEntry(size: e.size, at: e.dataOffset)
        try handle.seek(toOffset: e.dataOffset)
        return try readExact(Int(e.size))
    }

    public func copy(_ e: TarEntry, to url: URL) throws {
        _ = try endOfEntry(size: e.size, at: e.dataOffset)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw POSIXError(.EIO) }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        try handle.seek(toOffset: e.dataOffset)
        var remaining = e.size
        while remaining > 0 {
            let chunk = try readExact(Int(min(remaining, 1 << 20)))
            try out.write(contentsOf: chunk)
            remaining -= Int64(chunk.count)
        }
    }
}
