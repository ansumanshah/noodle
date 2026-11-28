import NoodleCore

/// Decides whether a status change was the runner exiting without a request from the app.
enum ModelServerWatch {
    /// Commands (start, stop) reload status under their own activity, so a poll only sees the quiet cases.
    static func exitedOnItsOwn(previous: LocalModelStatus, current: LocalModelStatus) -> Bool {
        current.phase == .stopped && (previous.phase == .ready || previous.phase == .starting)
    }
}
