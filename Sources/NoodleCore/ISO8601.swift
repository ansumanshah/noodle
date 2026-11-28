import Foundation

public enum ISO8601 {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    private static let lock = NSLock()
    public static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        lock.lock(); defer { lock.unlock() }
        return withFraction.date(from: s) ?? plain.date(from: s)
    }
    public static func string(_ d: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return withFraction.string(from: d)
    }
}
