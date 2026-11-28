import Foundation
import Compression
import zlib

/// Streaming gzip for layer blobs, using the Compression framework (raw DEFLATE) plus our own gzip framing.
public enum Gzip {
    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    struct CRC32 {
        var value: UInt32 = 0xFFFF_FFFF
        mutating func update(_ bytes: UnsafeRawBufferPointer) {
            for b in bytes { value = Gzip.crcTable[Int((value ^ UInt32(b)) & 0xff)] ^ (value >> 8) }
        }
        var final: UInt32 { value ^ 0xFFFF_FFFF }
    }

    public struct Result: Sendable {
        public var inputDigest: String     // sha256 of uncompressed bytes (the diff_id)
        public var outputDigest: String    // sha256 of the gzip file
        public var inputSize: Int64
        public var outputSize: Int64
    }

    public enum GzipError: Error { case badHeader, truncated, tooLarge, checksum, codec(String) }

    /// Compress `source` to `dest` as gzip, returning both digests so callers do not need a second pass.
    public static func compress(_ source: URL, to dest: URL) throws -> Result {
        let inH = try FileHandle(forReadingFrom: source)
        guard FileManager.default.createFile(atPath: dest.path, contents: nil) else { throw POSIXError(.EIO) }
        let outH = try FileHandle(forWritingTo: dest)
        defer { try? inH.close(); try? outH.close() }

        var inHash = SHA256Stream(), outHash = SHA256Stream()
        var crc = CRC32()
        var inSize: Int64 = 0, outSize: Int64 = 0

        func emit(_ d: Data) throws { try outH.write(contentsOf: d); outHash.update(d); outSize += Int64(d.count) }
        try emit(Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3]))

        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw GzipError.codec("init")
        }
        defer { compression_stream_destroy(&stream) }
        let dstCap = 1 << 16
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCap)
        defer { dst.deallocate() }

        var finished = false
        while !finished {
            let chunk = try inH.read(upToCount: 1 << 18) ?? Data()
            let isLast = chunk.isEmpty
            inHash.update(chunk); inSize += Int64(chunk.count)
            chunk.withUnsafeBytes { crc.update($0) }
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let base = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(bitPattern: 1)!
                stream.src_ptr = base
                stream.src_size = chunk.count
                repeat {
                    stream.dst_ptr = dst
                    stream.dst_size = dstCap
                    let status = compression_stream_process(&stream, isLast ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    let produced = dstCap - stream.dst_size
                    if produced > 0 { try emit(Data(bytes: dst, count: produced)) }
                    if status == COMPRESSION_STATUS_END { finished = true; break }
                    if status == COMPRESSION_STATUS_ERROR { throw GzipError.codec("deflate") }
                } while stream.src_size > 0 || (isLast && !finished) || stream.dst_size == 0
            }
        }
        var trailer = Data()
        var c = crc.final.littleEndian, s = UInt32(truncatingIfNeeded: inSize).littleEndian
        withUnsafeBytes(of: &c) { trailer.append(contentsOf: $0) }
        withUnsafeBytes(of: &s) { trailer.append(contentsOf: $0) }
        try emit(trailer)
        return Result(inputDigest: inHash.finalize(), outputDigest: outHash.finalize(), inputSize: inSize, outputSize: outSize)
    }

    /// Decompress a gzip file (one or more concatenated members) to `dest` with zlib, which checks each member's
    /// CRC32 and size. Returns sha256 of the output (the diff_id) and its size. Trailing bytes that are not a
    /// gzip member are rejected.
    public static func decompress(_ source: URL, to dest: URL, maximumSize: Int64 = .max) throws -> (digest: String, size: Int64) {
        let inH = try FileHandle(forReadingFrom: source)
        guard FileManager.default.createFile(atPath: dest.path, contents: nil) else { throw POSIXError(.EIO) }
        let outH = try FileHandle(forWritingTo: dest)
        defer { try? inH.close(); try? outH.close() }

        var strm = z_stream()
        guard inflateInit2_(&strm, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw GzipError.codec("init") }
        defer { inflateEnd(&strm) }
        let dstCap = 1 << 16
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCap)
        defer { dst.deallocate() }

        var hash = SHA256Stream()
        var total: Int64 = 0, members = 0, inMember = false
        while var chunk = try inH.read(upToCount: 1 << 18), !chunk.isEmpty {
            try chunk.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                strm.next_in = raw.bindMemory(to: UInt8.self).baseAddress
                strm.avail_in = uInt(raw.count)
                repeat {
                    try Task.checkCancellation()
                    strm.next_out = dst
                    strm.avail_out = uInt(dstCap)
                    let rc = inflate(&strm, Z_NO_FLUSH)
                    let produced = dstCap - Int(strm.avail_out)
                    if produced > 0 {
                        guard Int64(produced) <= maximumSize - total else { throw GzipError.tooLarge }
                        let d = Data(bytes: dst, count: produced)
                        try outH.write(contentsOf: d); hash.update(d); total += Int64(produced)
                    }
                    switch rc {
                    case Z_OK: inMember = true
                    case Z_STREAM_END: inMember = false; members += 1; _ = inflateReset(&strm)
                    case Z_BUF_ERROR where strm.avail_in == 0: return
                    case Z_DATA_ERROR:
                        let message = strm.msg.map { String(cString: $0) } ?? ""
                        throw message.contains("check") ? GzipError.checksum : members == 0 && !inMember ? .badHeader : .codec(message)
                    default: throw GzipError.codec("inflate \(rc)")
                    }
                } while strm.avail_in > 0 || strm.avail_out == 0
            }
        }
        guard members > 0 || inMember else { throw GzipError.badHeader }
        guard !inMember else { throw GzipError.truncated }
        return (hash.finalize(), total)
    }

    public static func isGzip(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let d = (try? h.read(upToCount: 2)) ?? Data()
        return d.count == 2 && d[d.startIndex] == 0x1f && d[d.startIndex + 1] == 0x8b
    }
}

import CryptoKit
/// Incremental SHA-256 returning the `sha256:hex` form.
struct SHA256Stream {
    private var h = SHA256()
    mutating func update(_ d: Data) { h.update(data: d) }
    mutating func finalize() -> String { "sha256:" + h.finalize().map { String(format: "%02x", $0) }.joined() }
}
