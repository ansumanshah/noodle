import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NoodleEngine

enum HTTPDate {
    static func now() -> String {
        var t = time(nil)
        var tmv = tm()
        gmtime_r(&t, &tmv)
        var buf = [Int8](repeating: 0, count: 64)
        strftime(&buf, buf.count, "%a, %d %b %Y %H:%M:%S GMT", &tmv)
        return String(cString: buf)
    }
}

enum JSONOut {
    static func encode<T: Encodable>(_ v: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(v)
    }
}
