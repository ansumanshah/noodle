import Foundation

/// A bundle replacement can succeed even when restarting the engine fails. Both entry points must
/// distinguish this from a failed replacement so the old GUI does not keep running after the swap.
public enum UpdateCommandOutcome: Equatable, Sendable {
    public static let restartFailedExitCode: Int32 = 3
    public static let restartErrorEnvironmentKey = "NOODLE_UPDATE_RESTART_ERROR"

    case installed(restartError: String?)
    case failed(String)

    public init(code: Int32, output: String) {
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch code {
        case 0: self = .installed(restartError: nil)
        case Self.restartFailedExitCode: self = .installed(restartError: message)
        default: self = .failed(message)
        }
    }
}
