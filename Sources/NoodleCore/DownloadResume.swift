import Foundation

/// Pure decisions for resuming an interrupted download with curl.
public enum DownloadResume {
    public enum Step: Equatable, Sendable { case fetch(from: UInt64), verify, restart }
    public enum Outcome: Equatable, Sendable { case done, retry(afterSeconds: Double), restart, fail }

    public static let maxStalls = 5

    private static let permanent: Set<Int32> = [1, 2, 3, 22, 23, 26, 27, 51, 60, 77]

    /// What to do with an on-disk partial before a curl attempt. totalBytes 0 means unknown.
    public static func next(partialBytes: UInt64, totalBytes: UInt64) -> Step {
        if totalBytes > 0 {
            if partialBytes > totalBytes { return .restart }
            if partialBytes == totalBytes { return .verify }
        }
        return .fetch(from: partialBytes)
    }

    /// Decide after one curl attempt exited with `code`, the partial having gone from `before` to `after` bytes.
    /// `stalls` is the count of consecutive attempts without progress before this one; returns the new count.
    public static func after(code: Int32, before: UInt64, after: UInt64, stalls: Int) -> (outcome: Outcome, stalls: Int) {
        if code == 0 { return (.done, 0) }
        if code == 33 {
            let s = stalls + 1
            return (s >= maxStalls ? .fail : .restart, s)
        }
        if permanent.contains(code) { return (.fail, stalls) }
        if after > before { return (.retry(afterSeconds: 1), 0) }
        let s = stalls + 1
        if s >= maxStalls { return (.fail, s) }
        return (.retry(afterSeconds: min(pow(2, Double(s)), 30)), s)
    }
}
