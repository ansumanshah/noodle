import Foundation
import OSLog
@_exported import NoodleCore
@_exported import NoodleImages
@_exported import NoodleVM

extension JSONEncoder {
    static var engine: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
extension JSONDecoder {
    static var engine: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
