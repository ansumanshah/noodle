import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NoodleEngine

enum ErrorMap {
    static func describe(_ error: Error) -> (Int, String) {
        switch error {
        case let e as APIError: return (e.status, e.message)
        case let e as EngineError: return (e.httpStatus, e.description)
        case let e as GuestError: return (e.errno == 2 ? 404 : 500, e.message)
        case let e as DecodingError: return (400, "invalid JSON: \(e)")
        default: return (500, "\(error)")
        }
    }
}
