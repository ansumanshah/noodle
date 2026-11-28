import Foundation

/// Plain-words rules shared by the app and the CLI. Pure, so both can be tested without a daemon.
public enum UpdateInstallWarning {
    /// What to tell a person before an install stops the engine. Nil when nothing is running.
    public static func message(running: Int?, rollback: Bool = false) -> String? {
        let action = rollback ? "Rolling back" : "Installing the update"
        guard let running else {
            return "Noodle could not check which containers are running. \(action) stops the engine and any running containers. The engine starts again only if it was running."
        }
        guard running > 0 else { return nil }
        let what = running == 1 ? "1 running container" : "\(running) running containers"
        return "\(action) stops Noodle's engine and starts it again, so \(what) will stop. Containers stay stopped unless their restart policy starts them."
    }
}

extension UpdatePolicy {
    /// True when an automatic check is allowed right now: on, and past the interval since the last one.
    public static func isDue(automatic: Bool, lastCheck: Date?, now: Date) -> Bool {
        guard let next = nextCheck(automatic: automatic, lastCheck: lastCheck, now: now) else { return false }
        return next <= now
    }
}
