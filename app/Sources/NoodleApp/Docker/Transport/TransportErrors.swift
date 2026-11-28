import Foundation
import Network

/// Hand-written HTTP/1.1 client for a Unix domain socket. One connection per request
/// (`Connection: close`), so there is no pool to hold memory while idle.

struct HTTPFailure: Error, LocalizedError, Sendable {
    var status: Int
    var message: String
    var errorDescription: String? { message.isEmpty ? "HTTP \(status)" : message }
}

enum TransportError: Error, LocalizedError {
    case unreachable(String)
    case malformed(String)
    case closed
    case timeout
    var errorDescription: String? {
        switch self {
        case .unreachable(let s): "Cannot reach the Noodle engine (\(s))"
        case .malformed(let s): "Malformed response: \(s)"
        case .closed: "Connection closed"
        case .timeout: "The Noodle engine did not answer in time"
        }
    }
}
