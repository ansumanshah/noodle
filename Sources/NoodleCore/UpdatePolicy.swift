import Foundation

/// Scheduling only: callers supply their clock and own any timer or network work.
public enum UpdatePolicy {
    public static let interval: TimeInterval = 6 * 60 * 60

    /// An overdue check runs once now, including after sleep, rather than catching up.
    public static func nextCheck(automatic: Bool, lastCheck: Date?, now: Date) -> Date? {
        guard automatic else { return nil }
        guard let lastCheck else { return now }
        return max(now, lastCheck.addingTimeInterval(interval))
    }
}
