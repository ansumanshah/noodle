import Foundation
import NoodleCore
import NoodleImages

public enum EngineError: Error, CustomStringConvertible, Sendable {
    case notFound(String)          // 404
    case conflict(String)          // 409
    case notModified(String)       // 304
    case badRequest(String)        // 400
    case invalid(String)           // 400
    case unavailable(String)       // 503, VM could not start
    case portInUse(String)         // 500, docker's "port is already allocated"
    case internalError(String)     // 500
    case unauthorized(String)      // 401

    public var description: String {
        switch self {
        case .notFound(let s), .conflict(let s), .notModified(let s), .badRequest(let s),
             .invalid(let s), .unavailable(let s), .portInUse(let s), .internalError(let s), .unauthorized(let s):
            return s
        }
    }

    /// HTTP status the Docker API layer should answer with.
    public var httpStatus: Int {
        switch self {
        case .notFound: return 404
        case .conflict: return 409
        case .notModified: return 304
        case .badRequest, .invalid: return 400
        case .unavailable: return 503
        case .unauthorized: return 401
        case .portInUse, .internalError: return 500
        }
    }
}

public enum ContainerStatus: String, Codable, Sendable { case created, running, paused, restarting, removing, exited, dead }
